import * as wh from "@certusone/wormhole-sdk"
import { PluginError } from "./utils"
import { IWormhole__factory, LogMessagePublishedEvent } from "../../../pkgs/sdk/src"
import * as ethers from "ethers"
import { Implementation__factory } from "@certusone/wormhole-sdk/lib/cjs/ethers-contracts"
import { retryAsyncUntilDefined } from "ts-retry/lib/cjs/retry"
import { ChainInfo } from "./plugin"
import { ScopedLogger } from "@wormhole-foundation/relayer-engine/relayer-engine/lib/helpers/logHelper"
import { tryNativeToHexString } from "@certusone/wormhole-sdk"

// fetch  the contract transaction receipt for the given sequence number emitted by the core relayer contract
export async function fetchReceipt(
  sequence: BigInt,
  chainId: wh.EVMChainId,
  provider: ethers.providers.Provider,
  chainConfig: ChainInfo
): Promise<ethers.ContractReceipt> {
  const coreWHContract = IWormhole__factory.connect(chainConfig.coreContract!, provider)
  const filter = coreWHContract.filters.LogMessagePublished(chainConfig.relayerAddress)
  const blockNumber = await coreWHContract.provider.getBlockNumber()
  for (let i = 0; i < 20; ++i) {
    let paginatedLogs
    if (i === 0) {
      paginatedLogs = await coreWHContract.queryFilter(filter, -30)
    } else {
      paginatedLogs = await coreWHContract.queryFilter(
        filter,
        blockNumber - (i + 1) * 20,
        blockNumber - i * 20
      )
    }
    const log = paginatedLogs.find(
      (log) => log.args.sequence.toString() === sequence.toString()
    )
    if (log) {
      return await log.getTransactionReceipt()
    }
  }
  try {
    return await retryAsyncUntilDefined(
      async () => {
        const paginatedLogs = await coreWHContract.queryFilter(filter, -50)
        const log = paginatedLogs.find(
          (log) => log.args.sequence.toString() === sequence.toString()
        )
        if (log) {
          return await log.getTransactionReceipt()
        }
        return undefined
      },
      { maxTry: 10, delay: 500 }
    )
  } catch {
    throw new PluginError("Could not find contract receipt", { sequence, chainId })
  }
}

export function filterLogs(
  rx: ethers.ContractReceipt,
  nonce: number,
  chainConfig: ChainInfo,
  logger: ScopedLogger
): {
  vaas: {
    sequence: string
    emitter: string
    bytes: string
  }[]
  deliveryVaaIdx: number
} {
  const onlyVAALogs = rx.logs.filter((log) => log.address === chainConfig.coreContract)
  const vaas = onlyVAALogs.flatMap((bridgeLog: ethers.providers.Log) => {
    const iface = Implementation__factory.createInterface()
    const log = iface.parseLog(bridgeLog) as unknown as LogMessagePublishedEvent
    // filter down to just synthetic batch
    if (log.args.nonce !== nonce) {
      return []
    }
    return [
      {
        sequence: log.args.sequence.toString(),
        emitter: wh.tryNativeToHexString(log.args.sender, "ethereum"),
        bytes: "",
      },
    ]
  })
  logger.debug(vaas)
  const emitterAddress = tryNativeToHexString(chainConfig.relayerAddress, "ethereum")
  const deliveryVaaIdx = vaas.findIndex((vaa) => vaa.emitter === emitterAddress)
  if (deliveryVaaIdx === -1) {
    throw new PluginError("CoreRelayerVaa not found in fetched vaas", {
      vaas,
    })
  }
  return { vaas, deliveryVaaIdx }
}
