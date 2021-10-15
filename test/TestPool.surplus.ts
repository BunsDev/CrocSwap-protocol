import { TestPool, makeTokenPool, Token, makeEtherPool } from './FacadePool'
import { expect } from "chai";
import "@nomiclabs/hardhat-ethers";
import { ethers } from 'hardhat';
import { toSqrtPrice, fromSqrtPrice, maxSqrtPrice, minSqrtPrice } from './FixedPoint';
import { solidity } from "ethereum-waffle";
import chai from "chai";
import { MockERC20 } from '../typechain/MockERC20';
import { BigNumber } from 'ethers';

chai.use(solidity);

describe('Pool Surplus', () => {
    let test: TestPool
    let testEth: TestPool
    let baseToken: Token
    let quoteToken: Token
    let sender: string
    const feeRate = 225 * 100

    beforeEach("deploy",  async () => {
       test = await makeTokenPool()
       testEth = await makeEtherPool()
       baseToken = await test.base
       quoteToken = await test.quote
       sender = await (await test.trader).getAddress() 

       await test.initPool(feeRate, 0, 1, 1.5)
       await (await test.dex).collect(sender, -100000, baseToken.address) 
       await (await test.dex).collect(sender, -250000, quoteToken.address) 

    })

    /*it("balance and withdraw", async() => {
        let quoteBal = (await test.quote.balanceOf(sender)).toNumber()
        let baseBal = (await test.base.balanceOf(sender)).toNumber()

        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(100000)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(250000);

        await (await test.dex).connect(await test.trader)
            .collect(sender, 40000, baseToken.address);
        await (await test.dex).connect(await test.trader)
            .collect(sender, 75000, quoteToken.address)
        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(60000)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(175000)

        expect(await test.base.balanceOf(sender)).to.equal(baseBal + 40000)
        expect(await test.quote.balanceOf(sender)).to.equal(quoteBal + 75000)
    })

    it("debit entry", async() => {
        let order = await test.prototypeOrder()

        order.hops[0].pools[0].passive.ambient.isAdd = true
        order.hops[0].pools[0].passive.ambient.liquidity = BigNumber.from(10000)
        order.open.useSurplus = true
        
        await test.testOrder(order)

        expect(await test.liquidity()).to.equal(10000)
        expect(await test.price()).to.eq(toSqrtPrice(1.5))
        expect(await test.snapBaseOwed()).to.equal(0)
        expect(await test.snapQuoteOwed()).to.equal(8168)

        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(100000-12251)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(250000)
     })

     it("debit partial entry", async() => {
        let order = await test.prototypeOrder()

        order.hops[0].pools[0].passive.ambient.isAdd = true
        order.hops[0].pools[0].passive.ambient.liquidity = BigNumber.from(100000)
        order.open.useSurplus = true
        
        await test.testOrder(order)

        expect(await test.liquidity()).to.equal(100000)
        expect(await test.price()).to.eq(toSqrtPrice(1.5))
        expect(await test.snapBaseOwed()).to.equal(22478)
        expect(await test.snapQuoteOwed()).to.equal(81653)

        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(0)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(250000)
     })

     it("credit entry", async() => {
        let order = await test.prototypeOrder()

        order.hops[0].pools[0].passive.ambient.isAdd = true
        order.hops[0].pools[0].passive.ambient.liquidity = BigNumber.from(10000)
        order.open.useSurplus = true
        
        await test.testOrder(order)

        order.hops[0].pools[0].passive.ambient.isAdd = false
        await test.testOrder(order)

        expect(await test.liquidity()).to.equal(0)
        expect(await test.price()).to.eq(toSqrtPrice(1.5))
        expect(await test.snapBaseOwed()).to.equal(0)
        expect(await test.snapQuoteOwed()).to.equal(-8164)

        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(100000-4)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(250000)
     })

     it("debit exit", async() => {
        let order = await test.prototypeOrder()

        order.hops[0].pools[0].passive.ambient.isAdd = true
        order.hops[0].pools[0].passive.ambient.liquidity = BigNumber.from(10000)
        order.hops[0].settlement.useSurplus = true
        
        await test.testOrder(order)

        expect(await test.liquidity()).to.equal(10000)
        expect(await test.price()).to.eq(toSqrtPrice(1.5))
        expect(await test.snapBaseOwed()).to.equal(12251)
        expect(await test.snapQuoteOwed()).to.equal(0)

        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(100000)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(250000-8168)
     })

     it("debit partial exit", async() => {
        let order = await test.prototypeOrder()

        order.hops[0].pools[0].passive.ambient.isAdd = true
        order.hops[0].pools[0].passive.ambient.liquidity = BigNumber.from(500000)
        order.hops[0].settlement.useSurplus = true
        
        await test.testOrder(order)

        expect(await test.liquidity()).to.equal(500000)
        expect(await test.price()).to.eq(toSqrtPrice(1.5))
        expect(await test.snapBaseOwed()).to.equal(612376)
        expect(await test.snapQuoteOwed()).to.equal(158252)

        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(100000)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(0)
     })

     it("credit exit", async() => {
        let order = await test.prototypeOrder()

        order.hops[0].pools[0].passive.ambient.isAdd = true
        order.hops[0].pools[0].passive.ambient.liquidity = BigNumber.from(10000)
        order.hops[0].settlement.useSurplus = true
        
        await test.testOrder(order)

        order.hops[0].pools[0].passive.ambient.isAdd = false
        await test.testOrder(order)

        expect(await test.liquidity()).to.equal(0)
        expect(await test.price()).to.eq(toSqrtPrice(1.5))
        expect(await test.snapBaseOwed()).to.equal(-12247)
        expect(await test.snapQuoteOwed()).to.equal(0)

        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(100000)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(250000-4)
     })*/

     it("swap hotpath", async() => {
        test.useHotPath = true
        await test.testMintAmbient(10000)

        await test.testSwapSurplus(true, true, 1000, toSqrtPrice(2.0))
        expect(await test.price()).to.gt(toSqrtPrice(1.5))
        expect(await test.snapBaseOwed()).to.equal(0)
        expect(await test.snapQuoteOwed()).to.equal(0)

        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(100000-1000)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(250000+648)
     })
       
     it("mint hotpath", async() => {
      test.useHotPath = true
      await test.testMintAmbient(10000)

      await test.testMint(3000, 5000, 1000, true)
      expect(await test.price()).to.eq(toSqrtPrice(1.5))
      expect(await test.snapBaseOwed()).to.equal(0)
      expect(await test.snapQuoteOwed()).to.equal(0)

      expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(35567)
      expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(211406)
      
     })
     
     it("burn hotpath", async() => {
        test.useHotPath = true
        await test.testMintAmbient(10000)

        await test.testMint(3000, 5000, 1000, true)
        await test.testBurn(3000, 5000, 1000, true)
      

        expect(await test.price()).to.eq(toSqrtPrice(1.5))
        expect(await test.snapBaseOwed()).to.equal(0)
        expect(await test.snapQuoteOwed()).to.equal(0)

        expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(100000-4)
        expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(250000-4)
      })

      it("mint ambient hotpath", async() => {
         test.useHotPath = true
         await test.testMintAmbient(10000)
   
         await test.testMintAmbient(50, true)
         expect(await test.price()).to.eq(toSqrtPrice(1.5))
         expect(await test.snapBaseOwed()).to.equal(0)
         expect(await test.snapQuoteOwed()).to.equal(0)
   
         expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(37290)
         expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(208192)         
        })
        
      it("burn ambient hotpath", async() => {
         test.useHotPath = true
         await test.testMintAmbient(10000)
 
         await test.testMintAmbient(50, true)
         await test.testBurnAmbient(50, true)
         expect(await test.price()).to.eq(toSqrtPrice(1.5))
         expect(await test.snapBaseOwed()).to.equal(0)
         expect(await test.snapQuoteOwed()).to.equal(0)
 
         expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(100000-4)
         expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(250000-4)
      }) 
})

describe('Pool Surplus Ether', () => {
   let test: TestPool
   let baseToken: Token
   let quoteToken: Token
   let sender: string
   const feeRate = 225 * 100

   beforeEach("deploy",  async () => {
      test = await makeEtherPool()
      baseToken = await test.base
      quoteToken = await test.quote
      sender = await (await test.trader).getAddress() 

      await test.initPool(feeRate, 0, 1, 1000000000)
      await (await test.dex).collect(sender, -1000000000000, baseToken.address, {value: 1000000000000 }) 
      await (await test.dex).collect(sender, -2500, quoteToken.address) 
   })

   it("balance and withdraw", async() => {
      let quoteBal = (await test.quote.balanceOf(sender))
      let baseBal = (await test.base.balanceOf(sender))

      expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(1000000000000)
      expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(2500);

      await (await test.dex).connect(await test.trader)
          .collect(sender, 200000000000, baseToken.address);
      await (await test.dex).connect(await test.trader)
          .collect(sender, 1000, quoteToken.address)
      expect(await (await test.query).querySurplus(sender, baseToken.address)).to.equal(800000000000)
      expect(await (await test.query).querySurplus(sender, quoteToken.address)).to.equal(1500)
  })

})