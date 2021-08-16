// SPDX-License-Identifier: Unlicensed

pragma solidity >0.7.1;

import './interfaces/ICrocSwapPool.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';

import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/CurveMath.sol';
import './libraries/SwapCurve.sol';

import './interfaces/ICrocSwapFactory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';

import './mixins/TickCensus.sol';
import './mixins/PositionRegistrar.sol';
import './mixins/LiquidityCurve.sol';
import './mixins/LevelBook.sol';
import './mixins/ProtocolAccount.sol';

import "hardhat/console.sol";

contract CrocSwapPool is ICrocSwapPool,
    PositionRegistrar, LiquidityCurve, LevelBook, ProtocolAccount {
    
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SwapCurve for CurveMath.CurveState;
    using CurveMath for CurveMath.CurveState;

    constructor (address factoryRef, address tokenQuote, address tokenBase,
                 uint24 feeRate, int24 tickUnits) {
        (factory_, tokenBase_, tokenQuote_, feeRate_) =
            (factoryRef, tokenBase, tokenQuote, feeRate);
        setTickSize(tickUnits);
    }
        
    function factory() external view override returns (address) {
        return factory_;
    }
    function token0() external view override returns (address) {
        return tokenQuote_;
    }
    function token1() external view override returns (address) {
        return tokenBase_;
    }
    function fee() external view override returns (uint24) {
        return feeRate_;
    }
    function tickSpacing() external view override returns (int24) {
        return getTickSize();
    }
    function maxLiquidityPerTick() external pure override returns (uint128) {
        return TickMath.MAX_TICK_LIQUIDITY;
    }
    
    function liquidity() external view override returns (uint128) {
        return activeLiquidity();
    }
    
    function tickBitmap (int16 wordPosition)
        external view override returns (uint256) {
        return mezzanineBitmap(wordPosition);
    }


    function initialize (uint160 price) external override {
        initPrice(price);
        int24 tick = TickMath.getTickAtSqrtRatio(price);
        emit Initialize(price, tick);
    }

    function slot0() external view override returns
        (uint160 sqrtPriceX96, int24 tick, uint8 feeProtocol, bool unlocked) {
        (sqrtPriceX96, tick) = loadPriceTick();
        feeProtocol = protocolCut_;
        unlocked = !reEntrantLocked_;
    }


    function mint (address owner, int24 lowerTick, int24 upperTick,
                   uint128 liqAdded, bytes calldata data)
        external override reEntrantLock returns (uint256 quoteOwed, uint256 baseOwed) {
        (, int24 midTick) = loadPriceTick();

        // Insert the range order into the book and position data structures
        uint256 odometer = addBookLiq(midTick, lowerTick, upperTick,
                                      liqAdded, tokenOdometer());
        addPosLiq(owner, lowerTick, upperTick, liqAdded, odometer);

        // Calculate and collect the necessary collateral from the user.
        (baseOwed, quoteOwed) = liquidityReceivable(liqAdded, lowerTick, upperTick);
        commitReserves(baseOwed, quoteOwed, data);
        emit Mint(msg.sender, owner, lowerTick, upperTick, liqAdded,
                  quoteOwed, baseOwed);
    }

    /* @notice Collects the required token collateral from the user as part of an
     *         add liquidity operation.
     * @params baseOwed The user's debit on the pair's base token side.
     * @params quoteOwed The user's debit on the pair's quote token side.
     * @params data Arbitrary callback data, previously passed in by the user, to be 
     *              sent to the user's callback function. */
    function commitReserves (uint256 baseOwed, uint256 quoteOwed,
                             bytes calldata data) private {
        uint256 initBase = baseOwed > 0 ? balanceBase() : 0;
        uint256 initQuote = quoteOwed > 0 ? balanceQuote() : 0;
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback
            (quoteOwed, baseOwed, data);
        require(baseOwed == 0 || balanceBase() >= initBase.add(baseOwed), "B");
        require(quoteOwed == 0 || balanceQuote() >= initQuote.add(quoteOwed), "Q");
    }

    
    function burn (address recipient, int24 lowerTick, int24 upperTick,
                   uint128 liqRemoved)
        external override reEntrantLock returns (uint256 quotePaid, uint256 basePaid) {
        (, int24 midTick) = loadPriceTick();

        // Remember feeMileage is the *global* liquidity growth in the range. We still
        // have to adjust for the growth that occured before the order was created.
        uint256 feeMileage =
            removeBookLiq(midTick, lowerTick, upperTick, liqRemoved, tokenOdometer());

        // Return the range order's original committed liquidity inflated by its
        // cumulative rewards
        uint256 rewards = burnPosLiq(msg.sender, lowerTick, upperTick,
                                     liqRemoved, feeMileage);
        (basePaid, quotePaid) = liquidityPayable(liqRemoved, uint128(rewards),
                                                  lowerTick, upperTick);

        if (basePaid > 0) {
            TransferHelper.safeTransfer(tokenBase_, recipient, basePaid);
        }
        if (quotePaid > 0) {
            TransferHelper.safeTransfer(tokenQuote_, recipient, quotePaid);
        }
        emit Burn(msg.sender, recipient, lowerTick, upperTick, liqRemoved,
                  quotePaid, basePaid);
    }
    

    function swap (address recipient, bool quoteToBase, int256 qty,
                   uint160 limitPrice, bytes calldata data)
        external override reEntrantLock returns (int256, int256) {

        /* A swap operation is a potentially long and iterative process that
         * repeatedly writes updates data on both the curve state and the swap
         * accumulator. To conserve gas, the strategy is to initialize and track
         * these structures in memory. Then only commit them back to EVM storage
         * when the operation is finalized. */
        CurveMath.CurveState memory curve = snapCurve();
        CurveMath.SwapFrame memory cntx = CurveMath.SwapFrame
            ({isBuy_: !quoteToBase,
                    inBaseQty_: (qty < 0) ? quoteToBase : !quoteToBase,
                    feeRate_: feeRate_, protoCut_: protocolCut_});
        CurveMath.SwapAccum memory accum = CurveMath.SwapAccum
            ({qtyLeft_: qty < 0 ? uint256(-qty) : uint256(qty),
                    cntx_: cntx, paidBase_: 0, paidQuote_: 0, paidProto_: 0});

        sweepSwapLiq(curve, accum, limitPrice);
        commitSwapCurve(curve);
        accumProtocolFees(accum);
        settleSwapFlows(recipient, curve, accum, data);
        
        return (accum.paidQuote_, accum.paidBase_);
    }


    /* @notice Executes the pending swap through the order book, adjusting the
     *         liquidity curve and level book as needed based on the swap's impact.
     *
     * @dev This is probably the most complex single function in the codebase. For
     *      small local moves, which don't cross extant levels in the book, it acts
     *      like a constant-product AMM curve. For large swaps which cross levels,
     *      it iteratively re-adjusts the AMM curve on every level cross, and performs
     *      the necessary book-keeping on each crossed level entry.
     *
     * @param curve The starting liquidity curve state. Any changes created by the 
     *              swap on this struct are updated in memory. But the caller is 
     *              responsible for committing the final state to EVM storage.
     * @param accum The specification for the executable swap. The realized flows
     *              on the swap will be written into the memory-based accumulator
     *              fields of this struct. The caller is responsible for paying and
     *              collecting those flows.
     * @param limitPrice The limit price of the swap. Expressed as the square root of
     *     the price in FixedPoint96. Important to note that this represents the limit
     *     of the final price of the *curve*. NOT the realized VWAP price of the swap.
     *     The swap will only ever execute up the maximum size which would keep the curve
     *     price within this bound, even if the specified quantity is higher. */
    function sweepSwapLiq (CurveMath.CurveState memory curve,
                           CurveMath.SwapAccum memory accum,
                           uint160 limitPrice) internal {
        bool isBuy = accum.cntx_.isBuy_;
        int24 midTick = TickMath.getTickAtSqrtRatio(curve.priceRoot_);
        uint256 mezzBitmap = mezzanineBitmap(midTick);
        
        // Keep iteratively executing more quantity until we either reach our limit price
        // or have zero quantity left to execute.
        while (hasSwapLeft(curve, accum, limitPrice)) {

            // Finds the next tick at which either A) an extant book level exists which
            // would bump the liquidity in the curve. Or B) we reach the end of our
            // locally visible bitmap. In either case we know that within this range,
            // we can execute the swap on a locallys stable constant-product AMM curve.
            (int24 bumpTick, bool spillsOver) = pinBitmap(isBuy, midTick, mezzBitmap);
            curve.swapToLimit(accum, bumpTick, limitPrice);

            // This check is redundant since we check it in the loop condition anyway.
            // But if we've fully exhausted the swap, this will short-circuit a number
            // of unnecessary gas-rich bookkeeping operations.
            if (hasSwapLeft(curve, accum, limitPrice)) {

                // The spills over variable indicates that we reaced the end of the
                // local bitmap, rather than actually hitting a level bump. Therefore
                // we should query the global bitmap, find the next level bitmap, and
                // keep swapping on the constant-product curve until we hit that point.
                if (spillsOver) {
                    int24 borderTick = bumpTick;
                    (bumpTick, mezzBitmap) = seekMezzSpill(borderTick, isBuy);

                    // In some corner cases the local bitmap border also happens to
                    // be the next level bump. In which case we're done. Otherwise,
                    // we keep swapping since we still have some distance on the curve
                    // to cover.
                    if (bumpTick != borderTick) {
                        curve.swapToLimit(accum, bumpTick, limitPrice);
                    }
                }

                // Perform book-keeping related to crossing the level bump, update
                // the locally tracked tick of the curve price (rather than wastefully
                // we calculating it since we already know it), then begin the swap
                // loop again.
                knockInTick(bumpTick, isBuy, curve);
                midTick = bumpTick;
            }
        }        
    }


    function hasSwapLeft (CurveMath.CurveState memory curve,
                          CurveMath.SwapAccum memory accum,
                          uint160 limitPrice) private pure returns (bool) {
        return accum.qtyLeft_ > 0 &&
            inLimitPrice(curve.priceRoot_, limitPrice, accum.cntx_.isBuy_);
    }
    
    function inLimitPrice (uint160 price, uint160 limitPrice, bool isBuy)
        private pure returns (bool) {
        return isBuy ? price < limitPrice : price > limitPrice;
    }


    /* @notice Performs all the necessary book keeping related to crossing an extant 
     *         level bump on the curve. 
     *
     * @dev Note that this function updates the level book data structure directly on
     *      the EVM storage. But it only updates the liquidity curve state *in memory*.
     *      This is for gas efficiency reasons, as the same curve struct may be updated
     *      many times in a single swap. The caller must take responsibility for 
     *      committing the final curve state back to EVM storage. 
     *
     * @params bumpTick The tick index where the bump occurs.
     * @params isBuy The direction the bump happens from. If true, curve's price is 
     *               moving through the bump starting from a lower price and going to a
     *               higher price. If false, the opposite.
     * @params curve The pre-bump state of the local constant-product AMM curve. Updated
     *               to reflect the liquidity added/removed from rolling through the
     *               bump. */
    function knockInTick (int24 bumpTick, bool isBuy,
                          CurveMath.CurveState memory curve) internal {
        if (Bitmaps.isTickFinite(bumpTick)) {
            int256 liqDelta = crossLevel(bumpTick, isBuy,
                                         curve.accum_.concTokenGrowth_);
            curve.liq_.concentrated_ = LiquidityMath.addDelta
                (curve.liq_.concentrated_, liqDelta.toInt128());
        }
    }
    
    
    function settleSwapFlows (address recipient,
                              CurveMath.CurveState memory curve,
                              CurveMath.SwapAccum memory accum,
                              bytes calldata data) internal {
        if (accum.cntx_.isBuy_) {
            if (accum.paidQuote_ < 0)
                TransferHelper.safeTransfer(tokenQuote_, recipient,
                                            uint256(-accum.paidQuote_));
            
            uint256 initBase = balanceBase();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback
                (accum.paidQuote_, accum.paidBase_, data);
            require(initBase.add(uint256(accum.paidBase_)) <= balanceBase(), "B");
        } else {
            if (accum.paidBase_ < 0)
                TransferHelper.safeTransfer(tokenBase_, recipient,
                                            uint256(-accum.paidBase_));
            
            uint256 initQuote = balanceQuote();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback
                (accum.paidQuote_, accum.paidBase_, data);
            require(initQuote.add(uint256(accum.paidQuote_)) <= balanceQuote(), "Q");
        }
        
        emit Swap(msg.sender, recipient, accum.paidQuote_, accum.paidBase_,
                  curve.priceRoot_, TickMath.getTickAtSqrtRatio(curve.priceRoot_));
    }
    
    
    function setFeeProtocol (uint8 protocolFee)
        protocolAuth external override { protocolCut_ = protocolFee; }
    
    function collectProtocol (address recipient)
        protocolAuth external override returns (uint128, uint128) {
        (uint128 baseFees, uint128 quoteFees) = disburseProtocol
            (recipient, tokenBase_, tokenQuote_);
        emit CollectProtocol(msg.sender, recipient, quoteFees, baseFees);
        return (quoteFees, baseFees);
    }
    
    function protocolFees() external view override returns (uint128, uint128) {
        (uint128 baseFees, uint128 quoteFees) = protoFeeAccum();
        return (quoteFees, baseFees);
    }
    
    modifier protocolAuth() {
        require(msg.sender == ICrocSwapFactory(factory_).owner());
        require(reEntrantLocked_ == false, "A");
        reEntrantLocked_ = true;
        _;
        reEntrantLocked_ = false;
    }
    
    modifier reEntrantLock() {
        require(reEntrantLocked_ == false, "A");
        reEntrantLocked_ = true;
        _;
        reEntrantLocked_ = false;
    }
    
    
    function balanceBase() private view returns (uint256) {
        return IERC20Minimal(tokenBase_).balanceOf(address(this));
    }
    
    function balanceQuote() private view returns (uint256) {
        return IERC20Minimal(tokenQuote_).balanceOf(address(this));
    }
    
    address private immutable factory_;
    address private immutable tokenBase_;
    address private immutable tokenQuote_;
    
    uint24 private immutable feeRate_;
    uint8 private protocolCut_;
    
    bool private reEntrantLocked_;    
}