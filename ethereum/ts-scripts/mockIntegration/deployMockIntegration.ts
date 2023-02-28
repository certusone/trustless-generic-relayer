import { init, loadChains, writeOutputFiles, getMockIntegration } from "../helpers/env"
import { deployMockIntegration } from "../helpers/deployments"
import { BigNumber } from "ethers"
import { tryNativeToHexString } from "@certusone/wormhole-sdk"
import { MockRelayerIntegration__factory } from "../../../sdk/src"
import { wait } from "../helpers/utils"

const processName = "deployMockIntegration"
init()
const chains = loadChains()

async function run() {
  console.log("Start!")
  const output: any = {
    mockIntegrations: [],
  }

  for (let i = 0; i < chains.length; i++) {
    const mockIntegration = await deployMockIntegration(chains[i])

    output.mockIntegrations.push(mockIntegration)
  }

  writeOutputFiles(output, processName)

  for (let i = 0; i < chains.length; i++) {
    console.log(`Registering emitters for chainId ${chains[i].chainId}`)
    const mockIntegration = getMockIntegration(chains[i])
    for (let j = 0; j < chains.length; j++) {
      console.log(`Registering emitter ${chains[j].chainId}`)
      const secondMockIntegration = output.mockIntegrations[j]
      await mockIntegration
        .registerEmitter(
          secondMockIntegration.chainId,
          "0x" + tryNativeToHexString(secondMockIntegration.address, "ethereum"),
          { gasLimit: 500000 }
        )
        .then(wait)
    }
  }
}

run().then(() => console.log("Done!"))
