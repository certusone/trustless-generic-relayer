import {
  ActionExecutor,
  assertBool,
  assertInt,
  CommonPluginEnv,
  ContractFilter,
  dbg,
  getScopedLogger,
  ParsedVaaWithBytes,
  parseVaaWithBytes,
  Plugin,
  PluginDefinition,
  Providers,
  sleep,
  StagingAreaKeyLock,
  Workflow,
} from "@wormhole-foundation/relayer-engine"
import * as wh from "@certusone/wormhole-sdk"
import { Logger } from "winston"
import { PluginError } from "./utils"
import { SignedVaa } from "@certusone/wormhole-sdk"
import {
  IWormhole,
  IWormhole__factory,
  RelayProvider__factory,
  LogMessagePublishedEvent,
  CoreRelayerStructs,
  DeliveryInstructionsContainer,
  parseDeliveryInstructionsContainer,
  parseRedeliveryByTxHashInstruction,
  parsePayloadType,
  RelayerPayloadId,
} from "../../../pkgs/sdk/src"
import * as ethers from "ethers"
import { Implementation__factory } from "@certusone/wormhole-sdk/lib/cjs/ethers-contracts"
import * as grpcWebNodeHttpTransport from "@improbable-eng/grpc-web-node-http-transport"
import { retryAsyncUntilDefined } from "ts-retry/lib/cjs/retry"

const wormholeRpc = "https://wormhole-v2-testnet-api.certus.one"

let PLUGIN_NAME: string = "GenericRelayerPlugin"

export interface ChainInfo {
  relayProvider: string
  coreContract?: IWormhole
  relayerAddress: string
  mockIntegrationContractAddress: string
}

export interface GenericRelayerPluginConfig {
  supportedChains: Map<wh.EVMChainId, ChainInfo>
  logWatcherSleepMs: number
  shouldRest: boolean
  shouldSpy: boolean
}

interface WorkflowPayload {
  payloadId: RelayerPayloadId
  coreRelayerDeliveryVaaIndex: number
  vaas: string[] // base64
  // only present when payload type is Redelivery
  coreRelayerRedeliveryVaa?: string // base64
}

interface WorkflowPayloadParsed {
  payloadId: RelayerPayloadId
  deliveryInstructionsContainer: DeliveryInstructionsContainer
  coreRelayerDeliveryVaaIndex: number
  coreRelayerDeliveryVaa: ParsedVaaWithBytes
  coreRelayerRedeliveryVaa?: ParsedVaaWithBytes
  vaas: Buffer[]
}

/*
 * DB types
 */

const RESOLVED = "resolved"
const PENDING = "pending"
interface Pending {
  startTime: string
  numTimesRetried: number
  hash: string
  nextRetryTime: string
}

interface Resolved {
  hash: string
}

interface Entry {
  chainId: number
  deliveryVaaIdx: number
  vaas: { emitter: string; sequence: string; bytes: string }[]
  allFetched: boolean
  // only present for Redeliveries
  redeliveryVaa?: string
}

export class GenericRelayerPlugin implements Plugin<WorkflowPayload> {
  readonly shouldSpy: boolean
  readonly shouldRest: boolean
  static readonly pluginName: string = PLUGIN_NAME
  readonly pluginName = GenericRelayerPlugin.pluginName
  pluginConfig: GenericRelayerPluginConfig

  constructor(
    readonly engineConfig: CommonPluginEnv,
    pluginConfigRaw: Record<string, any>,
    readonly logger: Logger
  ) {
    this.pluginConfig = GenericRelayerPlugin.validateConfig(pluginConfigRaw)
    this.shouldRest = this.pluginConfig.shouldRest
    this.shouldSpy = this.pluginConfig.shouldSpy
  }

  async afterSetup(
    providers: Providers,
    listenerResources?: {
      eventSource: (event: SignedVaa) => Promise<void>
      db: StagingAreaKeyLock
    }
  ) {
    // connect to the core wh contract for each chain
    for (const [chainId, info] of this.pluginConfig.supportedChains.entries()) {
      const chainName = wh.coalesceChainName(chainId)
      const { core } = wh.CONTRACTS.TESTNET[chainName]
      if (!core || !wh.isEVMChain(chainId)) {
        this.logger.error("No known core contract for chain", chainName)
        throw new PluginError("No known core contract for chain", { chainName })
      }
      const provider = providers.evm[chainId as wh.EVMChainId]
      info.coreContract = IWormhole__factory.connect(core, provider)
    }

    if (listenerResources) {
      setTimeout(
        () => this.fetchVaaWorker(listenerResources.eventSource, listenerResources.db),
        0
      )
    }
  }

  async fetchVaaWorker(
    eventSource: (event: SignedVaa) => Promise<void>,
    db: StagingAreaKeyLock
  ): Promise<void> {
    const logger = getScopedLogger(["fetchWorker"], this.logger)
    logger.debug(`Started fetchVaaWorker`)
    while (true) {
      await sleep(3_000) // todo: make configurable

      // track which delivery vaa hashes have all vaas ready this iteration
      let newlyResolved = new Map<string, Entry>()
      await db.withKey(
        [PENDING, RESOLVED],
        async (kv: { [RESOLVED]?: Resolved[]; [PENDING]?: Pending[] }) => {
          // if objects have not been crearted, initialize
          if (!kv.pending) {
            kv.pending = []
          }
          if (!kv.resolved) {
            kv.resolved = []
          }
          logger.debug(`Pending: ${JSON.stringify(kv.pending, undefined, 4)}`)
          logger.debug(`Resolved: ${JSON.stringify(kv.resolved, undefined, 4)}`)

          // filter to the pending items that are due to be retried
          const entriesToFetch = kv.pending.filter(
            (delivery) =>
              new Date(JSON.parse(delivery.nextRetryTime)).getTime() < Date.now()
          )
          if (entriesToFetch.length === 0) {
            return { newKV: kv, val: undefined }
          }

          logger.info(`Attempting to fetch ${entriesToFetch.length} entries`)
          await db.withKey(
            // get `Entry`s for each hash
            entriesToFetch.map((d) => d.hash),
            async (kv: Record<string, Entry>) => {
              const promises = Object.entries(kv).map(async ([hash, entry]) => {
                if (entry.allFetched) {
                  // nothing to do
                  logger.warn("Entry in pending but nothing to fetch " + hash)
                  return [hash, entry]
                }
                const newEntry: Entry = await this.fetchEntry(hash, entry, logger)
                if (newEntry.allFetched) {
                  newlyResolved.set(hash, newEntry)
                }
                return [hash, newEntry]
              })

              const newKV = Object.fromEntries(await Promise.all(promises))
              return { newKV, val: undefined }
            }
          )

          // todo: gc resolved eventually
          // todo: currently not used, but the idea is to refire resolved events
          // in the case of a restart or smt. Maybe should just remove it for now...
          kv.resolved.push(
            ...Array.from(newlyResolved.keys()).map((hash) => ({
              hash,
            }))
          )
          kv.pending = kv.pending.filter((p) => !newlyResolved.has(p.hash))

          return { newKV: kv, val: undefined }
        }
      )
      // kick off an engine listener event for each resolved delivery vaa
      for (const entry of newlyResolved.values()) {
        this.logger.info("Kicking off engine listener event for resolved entry")
        if (entry.redeliveryVaa) {
          eventSource(Buffer.from(entry.redeliveryVaa, "base64"))
        } else {
          eventSource(Buffer.from(entry.vaas[entry.deliveryVaaIdx].bytes, "base64"))
        }
      }
    }
  }

  async fetchEntry(hash: string, value: Entry, logger: Logger): Promise<Entry> {
    // track if there are missing vaas after trying to fetch
    let hasMissingVaas = false
    const vaas = await Promise.all(
      value.vaas.map(async ({ emitter, sequence, bytes }, idx) => {
        // skip if vaa has already been fetched
        if (bytes.length !== 0) {
          return { emitter, sequence, bytes }
        }
        try {
          // try to fetch vaa from guardian rpc
          const resp = await wh.getSignedVAA(
            wormholeRpc,
            value.chainId as wh.EVMChainId,
            emitter,
            sequence,
            { transport: grpcWebNodeHttpTransport.NodeHttpTransport() }
          )
          logger.info(`Fetched vaa ${idx} for delivery ${hash}`)
          return {
            emitter,
            sequence,
            // base64 encode
            bytes: Buffer.from(resp.vaaBytes).toString("base64"),
          }
        } catch (e) {
          hasMissingVaas = true
          this.logger.debug(e)
          return { emitter, sequence, bytes: "" }
        }
      })
    )
    // if all vaas have been fetched, mark this hash as resolved
    return { ...value, vaas, allFetched: !hasMissingVaas }
  }

  // listen to core relayer contract on each chain
  getFilters(): ContractFilter[] {
    return Array.from(this.pluginConfig.supportedChains.entries()).map(
      ([chainId, c]) => ({ emitterAddress: c.relayerAddress, chainId })
    )
  }

  async consumeEvent(
    coreRelayerVaa: ParsedVaaWithBytes,
    db: StagingAreaKeyLock,
    _providers: Providers
  ): Promise<{ workflowData?: WorkflowPayload }> {
    this.logger.debug(
      `Consuming event from chain ${
        coreRelayerVaa.emitterChain
      } with seq ${coreRelayerVaa.sequence.toString()} and hash ${Buffer.from(
        coreRelayerVaa.hash
      ).toString("base64")}`
    )
    const payloadId = parsePayloadType(coreRelayerVaa.payload)
    if (payloadId !== RelayerPayloadId.Delivery) {
      // todo: support redelivery
    }
    switch (payloadId) {
      case RelayerPayloadId.Delivery:
        return this.consumeDeliveryEvent(coreRelayerVaa, db)
      case RelayerPayloadId.Redelivery:
        return this.consumeRedeliveryEvent(coreRelayerVaa, db)
    }
  }

  async consumeRedeliveryEvent(
    coreRelayerVaa: ParsedVaaWithBytes,
    db: StagingAreaKeyLock
  ): Promise<{ workflowData?: WorkflowPayload }> {}

  async consumeDeliveryEvent(
    coreRelayerVaa: ParsedVaaWithBytes,
    db: StagingAreaKeyLock
  ): Promise<{ workflowData?: WorkflowPayload }> {
    const hash = coreRelayerVaa.hash.toString("base64")
    const { [hash]: fetched } = await db.getKeys<Record<typeof hash, Entry>>([hash])

    if (fetched?.allFetched) {
      // if all vaas have been fetched, kick off workflow
      this.logger.info(`All fetched, queueing workflow for ${hash}...`)
      return dbg(
        {
          workflowData: {
            payloadId: RelayerPayloadId.Delivery,
            coreRelayerDeliveryVaaIndex: fetched.deliveryVaaIdx,
            vaas: fetched.vaas.map((v) => v.bytes),
          },
        },
        "workflow from consume event"
      )
    } else {
      this.logger.info(
        `Not fetched, fetching receipt and filtering to synthetic batch for ${hash}...`
      )
      const chainId = coreRelayerVaa.emitterChain as wh.EVMChainId
      const rx = await this.fetchReceipt(coreRelayerVaa.sequence, chainId)
      // parse rx for seqs and emitters

      const { vaas, deliveryVaaIdx } = this.filterLogs(rx, chainId, coreRelayerVaa)
      vaas[deliveryVaaIdx].bytes = coreRelayerVaa.bytes.toString("base64")

      // create entry and pending in db
      const newEntry: Entry = {
        vaas,
        chainId,
        deliveryVaaIdx,
        allFetched: false,
      }

      const maybeResolvedEntry = await this.fetchEntry(hash, newEntry, this.logger)
      if (maybeResolvedEntry.allFetched) {
        this.logger.info("Resolved entry immediately")
        return {
          workflowData: {
            payloadId: RelayerPayloadId.Delivery,
            coreRelayerDeliveryVaaIndex: maybeResolvedEntry.deliveryVaaIdx,
            vaas: maybeResolvedEntry.vaas.map((v) => v.bytes),
          },
        }
      }

      this.logger.debug(`Entry: ${JSON.stringify(newEntry, undefined, 4)}`)
      await db.withKey(
        [hash, PENDING],
        // note _hash is actually the value of the variable `hash`, but ts will not
        // let this be expressed
        async (kv: { [PENDING]: Pending[]; _hash: Entry }) => {
          // @ts-ignore
          let oldEntry: Entry | null = kv[hash]
          if (oldEntry?.allFetched) {
            return { newKV: kv, val: undefined }
          }
          const now = Date.now().toString()
          kv.pending.push({
            nextRetryTime: now,
            numTimesRetried: 0,
            startTime: now,
            hash,
          })
          // @ts-ignore
          kv[hash] = newEntry
          return { newKV: kv, val: undefined }
        }
      )

      // do not create workflow until we have collected all VAAs
      return {}
    }
  }

  // fetch  the contract transaction receipt for the given sequence number emitted by the core relayer contract
  async fetchReceipt(
    sequence: BigInt,
    chainId: wh.EVMChainId
  ): Promise<ethers.ContractReceipt> {
    const config = this.pluginConfig.supportedChains.get(chainId)!
    const coreWHContract = config.coreContract!
    const filter = coreWHContract.filters.LogMessagePublished(config.relayerAddress)

    const blockNumber = await coreWHContract.provider.getBlockNumber()
    for (let i = 0; i < 20; ++i) {
      let paginatedLogs
      if (i === 0) {
        paginatedLogs = await coreWHContract.queryFilter(filter, -20)
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
          const paginatedLogs = await coreWHContract.queryFilter(filter, -20)
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

  filterLogs(
    rx: ethers.ContractReceipt,
    chainId: wh.EVMChainId,
    coreRelayerVaa: ParsedVaaWithBytes
  ): {
    vaas: {
      sequence: string
      emitter: string
      bytes: string
    }[]
    deliveryVaaIdx: number
  } {
    const onlyVAALogs = rx.logs.filter(
      (log) =>
        log.address ===
        this.pluginConfig.supportedChains.get(chainId)?.coreContract?.address
    )
    const vaas = onlyVAALogs.flatMap((bridgeLog: ethers.providers.Log) => {
      const iface = Implementation__factory.createInterface()
      const log = iface.parseLog(bridgeLog) as unknown as LogMessagePublishedEvent
      // filter down to just synthetic batch
      if (log.args.nonce !== coreRelayerVaa.nonce) {
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
    this.logger.debug(vaas)
    const deliveryVaaIdx = vaas.findIndex(
      (vaa) =>
        vaa.emitter ===
        wh.tryNativeToHexString(
          wh.tryUint8ArrayToNative(coreRelayerVaa.emitterAddress, "ethereum"),
          "ethereum"
        )
    )
    if (deliveryVaaIdx === -1) {
      throw new PluginError("CoreRelayerVaa not found in fetched vaas", {
        vaas,
      })
    }
    return { vaas, deliveryVaaIdx }
  }

  async handleWorkflow(
    workflow: Workflow<WorkflowPayload>,
    _providers: Providers,
    execute: ActionExecutor
  ): Promise<void> {
    const payload = this.parseWorkflowPayload(workflow)
    switch (payload.payloadId) {
      case RelayerPayloadId.Delivery:
    }
  }

  async handleDeliveryWorkflow(
    workflow: Workflow<WorkflowPayload>,
    _providers: Providers,
    execute: ActionExecutor
  ): Promise<void> {
    this.logger.info("Got workflow")
    this.logger.info(JSON.stringify(workflow, undefined, 2))
    this.logger.info(workflow.data.coreRelayerDeliveryVaaIndex)
    this.logger.info(workflow.data.vaas)
    console.log("sanity console log")

    const payload = this.parseWorkflowPayload(workflow)
    for (let i = 0; i < payload.deliveryInstructionsContainer.instructions.length; i++) {
      const ix = payload.deliveryInstructionsContainer.instructions[i]

      // todo: add wormhole fee
      const budget = ix.applicationBudgetTarget.add(ix.maximumRefundTarget).add(100)

      const chainId = ix.targetChain as wh.EVMChainId
      // todo: consider parallelizing this
      await execute.onEVM({
        chainId,
        f: async ({ wallet }) => {
          const relayProvider = RelayProvider__factory.connect(
            this.pluginConfig.supportedChains.get(chainId)!.relayProvider,
            wallet
          )

          const input: CoreRelayerStructs.TargetDeliveryParametersSingleStruct = {
            encodedVMs: payload.vaas,
            deliveryIndex: payload.coreRelayerVaaIndex,
            multisendIndex: i,
            relayerRefundAddress: relayProvider.address,
          }

          if (!(await relayProvider.approvedSender(wallet.address))) {
            this.logger.warn(
              `Approved sender not set correctly for chain ${chainId}, should be ${wallet.address}`
            )
            return
          }

          relayProvider
            .deliverSingle(input, { value: budget, gasLimit: 3000000 })
            .then((x) => x.wait())

          this.logger.info(
            `Relayed instruction ${i + 1} of ${
              payload.deliveryInstructionsContainer.instructions.length
            } to chain ${chainId}`
          )
        },
      })
    }
  }

  static validateConfig(
    pluginConfigRaw: Record<string, any>
  ): GenericRelayerPluginConfig {
    const supportedChains =
      pluginConfigRaw.supportedChains instanceof Map
        ? pluginConfigRaw.supportedChains
        : new Map(
            Object.entries(pluginConfigRaw.supportedChains).map(([chainId, info]) => [
              Number(chainId) as wh.EVMChainId,
              info,
            ])
          )

    return {
      supportedChains,
      logWatcherSleepMs: assertInt(
        pluginConfigRaw.logWatcherSleepMs,
        "logWatcherSleepMs"
      ),
      shouldRest: assertBool(pluginConfigRaw.shouldRest, "shouldRest"),
      shouldSpy: assertBool(pluginConfigRaw.shouldSpy, "shouldSpy"),
    }
  }

  parseWorkflowPayload(workflow: Workflow<WorkflowPayload>): WorkflowPayloadParsed {
    this.logger.info("Parse workflow")
    const payloadId = workflow.data.payloadId
    const vaas = workflow.data.vaas.map((s) => Buffer.from(s, "base64"))
    const coreRelayerRedeliveryVaa =
      (workflow.data.coreRelayerRedeliveryVaa &&
        parseVaaWithBytes(
          Buffer.from(workflow.data.coreRelayerRedeliveryVaa, "base64")
        )) ||
      undefined
    const coreRelayerVaa = parseVaaWithBytes(
      vaas[workflow.data.coreRelayerDeliveryVaaIndex]
    )
    return {
      payloadId,
      coreRelayerDeliveryVaa: coreRelayerVaa,
      coreRelayerDeliveryVaaIndex: workflow.data.coreRelayerDeliveryVaaIndex,
      coreRelayerRedeliveryVaa,
      vaas,
      deliveryInstructionsContainer: parseDeliveryInstructionsContainer(
        coreRelayerVaa.payload
      ),
    }
  }
}

class Definition implements PluginDefinition<GenericRelayerPluginConfig, Plugin> {
  pluginName: string = PLUGIN_NAME

  init(pluginConfig: any): {
    fn: (engineConfig: any, logger: Logger) => GenericRelayerPlugin
    pluginName: string
  } {
    const pluginConfigParsed: GenericRelayerPluginConfig =
      GenericRelayerPlugin.validateConfig(pluginConfig)
    return {
      fn: (env, logger) => new GenericRelayerPlugin(env, pluginConfigParsed, logger),
      pluginName: this.pluginName,
    }
  }
}

// todo: move to sdk
export default new Definition()
