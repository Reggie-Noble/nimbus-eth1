# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils, times, tables, os, sets],
  eth/[rlp, trie, eip1559],
  stint, chronicles, stew/results,
  "."/[config, types, helpers],
  ../../nimbus/[vm_types, vm_state, transaction],
  ../../nimbus/common/common,
  ../../nimbus/db/accounts_cache,
  ../../nimbus/utils/utils,
  ../../nimbus/core/pow/difficulty,
  ../../nimbus/core/dao,
  ../../nimbus/core/executor/[process_transaction, executor_helpers]

import stew/byteutils
const
  wrapExceptionEnabled* {.booldefine.} = true
  stdinSelector = "stdin"

type
  Dispatch = object
    stdout: JsonNode
    stderr: JsonNode

  ExecOutput = object
    result: ExecutionResult
    alloc: GenesisAlloc

  TestVMState = ref object of BaseVMState
    blockHashes: Table[uint64, Hash256]
    hashError: string

proc init(_: type Dispatch): Dispatch =
  result.stdout = newJObject()
  result.stderr = newJObject()

proc dispatch(dis: var Dispatch, baseDir, fName, name: string, obj: JsonNode) =
  case fName
  of "stdout":
    dis.stdout[name] = obj
  of "stderr":
    dis.stderr[name] = obj
  of "":
    # don't save
    discard
  else:
    # save to file
    let path = if baseDir.len > 0:
                 baseDir / fName
               else:
                 fName
    writeFile(path, obj.pretty)

proc dispatchOutput(ctx: var TransContext, conf: T8NConf, res: ExecOutput) =
  var dis = Dispatch.init()
  createDir(conf.outputBaseDir)

  dis.dispatch(conf.outputBaseDir, conf.outputAlloc, "alloc", @@(res.alloc))
  dis.dispatch(conf.outputBaseDir, conf.outputResult, "result", @@(res.result))

  let chainId = conf.stateChainId.ChainId
  let txList = ctx.txList(chainId)

  let body = @@(rlp.encode(txList))
  dis.dispatch(conf.outputBaseDir, conf.outputBody, "body", body)

  if dis.stdout.len > 0:
    stdout.write(dis.stdout.pretty)
    stdout.write("\n")

  if dis.stderr.len > 0:
    stderr.write(dis.stderr.pretty)
    stderr.write("\n")

proc envToHeader(env: EnvStruct): BlockHeader =
  BlockHeader(
    coinbase   : env.currentCoinbase,
    difficulty : env.currentDifficulty.get(0.u256),
    mixDigest  : env.currentRandom.get(Hash256()),
    blockNumber: env.currentNumber,
    gasLimit   : env.currentGasLimit,
    timestamp  : env.currentTimestamp,
    stateRoot  : emptyRlpHash,
    fee        : env.currentBaseFee
  )

proc postState(db: AccountsCache, alloc: var GenesisAlloc) =
  for accAddr in db.addresses():
    var acc = GenesisAccount(
      code: db.getCode(accAddr),
      balance: db.getBalance(accAddr),
      nonce: db.getNonce(accAddr)
    )

    for k, v in db.storage(accAddr):
      acc.storage[k] = v
    alloc[accAddr] = acc

proc genAddress(vmState: BaseVMState, tx: Transaction, sender: EthAddress): EthAddress =
  if tx.to.isNone:
    let creationNonce = vmState.readOnlyStateDB().getNonce(sender)
    result = generateAddress(sender, creationNonce)

proc toTxReceipt(vmState: BaseVMState,
                 rec: Receipt,
                 tx: Transaction,
                 sender: EthAddress,
                 txIndex: int,
                 gasUsed: GasInt): TxReceipt =

  let contractAddress = genAddress(vmState, tx, sender)
  TxReceipt(
    txType: tx.txType,
    root: if rec.isHash: rec.hash else: Hash256(),
    status: rec.status,
    cumulativeGasUsed: rec.cumulativeGasUsed,
    logsBloom: rec.bloom,
    logs: rec.logs,
    transactionHash: rlpHash(tx),
    contractAddress: contractAddress,
    gasUsed: gasUsed,
    blockHash: Hash256(),
    transactionIndex: txIndex
  )

proc calcLogsHash(receipts: openArray[Receipt]): Hash256 =
  var logs: seq[Log]
  for rec in receipts:
    logs.add rec.logs
  rlpHash(logs)

proc dumpTrace(txIndex: int, txHash: Hash256, traceResult: JsonNode) =
  let fName = "trace-$1-$2.jsonl" % [$txIndex, $txHash]
  writeFile(fName, traceResult.pretty)

proc exec(ctx: var TransContext,
          vmState: BaseVMState,
          stateReward: Option[UInt256],
          header: BlockHeader): ExecOutput =

  let txList = ctx.parseTxs(vmState.com.chainId)

  var
    receipts = newSeqOfCap[TxReceipt](txList.len)
    rejected = newSeq[RejectedTx]()
    includedTx = newSeq[Transaction]()

  if vmState.com.daoForkSupport and
     vmState.com.daoForkBlock.get == vmState.blockNumber:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  vmState.receipts = newSeqOfCap[Receipt](txList.len)
  vmState.cumulativeGasUsed = 0

  for txIndex, txRes in txList:
    if txRes.isErr:
      rejected.add RejectedTx(
        index: txIndex,
        error: txRes.error
      )
      continue

    let tx = txRes.get
    var sender: EthAddress
    if not tx.getSender(sender):
      rejected.add RejectedTx(
        index: txIndex,
        error: "Could not get sender"
      )
      continue

    let rc = vmState.processTransaction(tx, sender, header)

    if vmState.tracingEnabled:
      dumpTrace(txIndex, rlpHash(tx), vmState.getTracingResult)

    if rc.isErr:
      rejected.add RejectedTx(
        index: txIndex,
        error: "processTransaction failed"
      )
      continue

    let gasUsed = rc.get()
    let rec = vmState.makeReceipt(tx.txType)
    vmState.receipts.add rec
    receipts.add toTxReceipt(
      vmState, rec,
      tx, sender, txIndex, gasUsed
    )
    includedTx.add tx

  # Add mining reward? (-1 means rewards are disabled)
  if stateReward.isSome and stateReward.get >= 0:
    # Add mining reward. The mining reward may be `0`, which only makes a difference in the cases
    # where
    # - the coinbase suicided, or
    # - there are only 'bad' transactions, which aren't executed. In those cases,
    #   the coinbase gets no txfee, so isn't created, and thus needs to be touched
    let blockReward = stateReward.get()
    var mainReward = blockReward
    for uncle in ctx.env.ommers:
      var uncleReward = 8.u256 - uncle.delta.u256
      uncleReward = uncleReward * blockReward
      uncleReward = uncleReward div 8.u256
      vmState.mutateStateDB:
        db.addBalance(uncle.address, uncleReward)
      mainReward += blockReward div 32.u256

    vmState.mutateStateDB:
      db.addBalance(ctx.env.currentCoinbase, mainReward)
      db.persist(clearCache = false)

  let miner = ctx.env.currentCoinbase
  if vmState.com.forkGTE(Spurious):
    # EIP158/161 state clearing
    vmState.mutateStateDB:
      if db.accountExists(miner) and db.isEmptyAccount(miner):
        db.deleteAccount(miner)
        # do not clear cache, we need the cache when constructing
        # post state
        db.persist(clearCache = false)

  let stateDB = vmState.stateDB
  stateDB.postState(result.alloc)
  result.result = ExecutionResult(
    stateRoot   : stateDB.rootHash,
    txRoot      : includedTx.calcTxRoot,
    receiptsRoot: calcReceiptRoot(vmState.receipts),
    logsHash    : calcLogsHash(vmState.receipts),
    bloom       : createBloom(vmState.receipts),
    receipts    : system.move(receipts),
    rejected    : system.move(rejected),
    # geth using both vmContext.Difficulty and vmContext.Random
    # therefore we cannot use vmState.difficulty
    currentDifficulty: ctx.env.currentDifficulty,
    gasUsed     : vmState.cumulativeGasUsed,
    currentBaseFee: ctx.env.currentBaseFee
  )

template wrapException(body: untyped) =
  when wrapExceptionEnabled:
    try:
      body
    except IOError as e:
      raise newError(ErrorIO, e.msg)
    except RlpError as e:
      raise newError(ErrorRlp, e.msg)
    except ValueError as e:
      raise newError(ErrorJson, e.msg)
  else:
    body

proc setupAlloc(stateDB: AccountsCache, alloc: GenesisAlloc) =
  for accAddr, acc in alloc:
    stateDB.setNonce(accAddr, acc.nonce)
    stateDB.setCode(accAddr, acc.code)
    stateDB.setBalance(accAddr, acc.balance)

    for slot, value in acc.storage:
      stateDB.setStorage(accAddr, slot, value)

method getAncestorHash(vmState: TestVMState; blockNumber: BlockNumber): Hash256 {.gcsafe.} =
  # we can't raise exception here, it'll mess with EVM exception handler.
  # so, store the exception for later using `hashError`
  let num = blockNumber.truncate(uint64)
  var h = Hash256()
  if vmState.blockHashes.len == 0:
    vmState.hashError = "getAncestorHash($1) invoked, no blockhashes provided" % [$num]
    return h

  vmState.blockHashes.withValue(num, val) do:
    h = val[]
  do:
    vmState.hashError = "getAncestorHash($1) invoked, blockhash for that block not provided" % [$num]

  return h

proc parseChainConfig(network: string): ChainConfig =
  try:
    result = getChainConfig(network)
  except ValueError as e:
    raise newError(ErrorConfig, e.msg)

proc calcBaseFee(env: EnvStruct): UInt256 =
  if env.parentGasUsed.isNone:
    raise newError(ErrorConfig,
      "'parentBaseFee' exists but missing 'parentGasUsed' in env section")

  if env.parentGasLimit.isNone:
    raise newError(ErrorConfig,
      "'parentBaseFee' exists but missing 'parentGasLimit' in env section")

  calcEip1599BaseFee(
    env.parentGasLimit.get,
    env.parentGasUsed.get,
    env.parentBaseFee.get)

proc transitionAction*(ctx: var TransContext, conf: T8NConf) =
  wrapException:
    var tracerFlags = {
      TracerFlags.DisableMemory,
      TracerFlags.DisableStorage,
      TracerFlags.DisableState,
      TracerFlags.DisableStateDiff,
      TracerFlags.DisableReturnData
    }

    if conf.traceEnabled:
      tracerFlags.incl TracerFlags.EnableTracing
      if conf.traceMemory: tracerFlags.excl TracerFlags.DisableMemory
      if conf.traceNostack: tracerFlags.incl TracerFlags.DisableStack
      if conf.traceReturnData: tracerFlags.excl TracerFlags.DisableReturnData

    if conf.inputAlloc.len == 0 and conf.inputEnv.len == 0 and conf.inputTxs.len == 0:
      raise newError(ErrorConfig, "either one of input is needeed(alloc, txs, or env)")

    let config = parseChainConfig(conf.stateFork)
    config.chainId = conf.stateChainId.ChainId

    let com = CommonRef.new(newMemoryDb(), config, pruneTrie = true)

    # We need to load three things: alloc, env and transactions.
    # May be either in stdin input or in files.

    if conf.inputAlloc == stdinSelector or
       conf.inputEnv == stdinSelector or
       conf.inputTxs == stdinSelector:
      ctx.parseInputFromStdin()

    if conf.inputAlloc != stdinSelector and conf.inputAlloc.len > 0:
      let n = json.parseFile(conf.inputAlloc)
      ctx.parseAlloc(n)

    if conf.inputEnv != stdinSelector and conf.inputEnv.len > 0:
      let n = json.parseFile(conf.inputEnv)
      ctx.parseEnv(n)

    if conf.inputTxs != stdinSelector and conf.inputTxs.len > 0:
      if conf.inputTxs.endsWith(".rlp"):
        let data = readFile(conf.inputTxs)
        ctx.parseTxsRlp(data.strip(chars={'"'}))
      else:
        let n = json.parseFile(conf.inputTxs)
        ctx.parseTxs(n)

    let uncleHash = if ctx.env.parentUncleHash == Hash256():
                      EMPTY_UNCLE_HASH
                    else:
                      ctx.env.parentUncleHash

    let parent = BlockHeader(
      stateRoot: emptyRlpHash,
      timestamp: ctx.env.parentTimestamp,
      difficulty: ctx.env.parentDifficulty.get(0.u256),
      ommersHash: uncleHash,
      blockNumber: ctx.env.currentNumber - 1.toBlockNumber
    )

    # Sanity check, to not `panic` in state_transition
    if com.isLondon(ctx.env.currentNumber):
      if ctx.env.currentBaseFee.isSome:
        # Already set, currentBaseFee has precedent over parentBaseFee.
        discard
      elif ctx.env.parentBaseFee.isSome:
        ctx.env.currentBaseFee = some(calcBaseFee(ctx.env))
      else:
        raise newError(ErrorConfig, "EIP-1559 config but missing 'currentBaseFee' in env section")

    if com.forkGTE(MergeFork):
      if ctx.env.currentRandom.isNone:
        raise newError(ErrorConfig, "post-merge requires currentRandom to be defined in env")

      if ctx.env.currentDifficulty.isSome and ctx.env.currentDifficulty.get() != 0:
        raise newError(ErrorConfig, "post-merge difficulty must be zero (or omitted) in env")
      ctx.env.currentDifficulty = none(DifficultyInt)

    elif ctx.env.currentDifficulty.isNone:
      if ctx.env.parentDifficulty.isNone:
        raise newError(ErrorConfig, "currentDifficulty was not provided, and cannot be calculated due to missing parentDifficulty")

      if ctx.env.currentNumber == 0.toBlockNumber:
        raise newError(ErrorConfig, "currentDifficulty needs to be provided for block number 0")

      if ctx.env.currentTimestamp <= ctx.env.parentTimestamp:
        raise newError(ErrorConfig,
          "currentDifficulty cannot be calculated -- currentTime ($1) needs to be after parent time ($2)" %
            [$ctx.env.currentTimestamp, $ctx.env.parentTimestamp])

      ctx.env.currentDifficulty = some(calcDifficulty(com,
        ctx.env.currentTimestamp, parent))

    let header  = envToHeader(ctx.env)

    let vmState = TestVMState(
      blockHashes: ctx.env.blockHashes,
      hashError: ""
    )

    vmState.init(
      parent      = parent,
      header      = header,
      com         = com,
      tracerFlags = (if conf.traceEnabled: tracerFlags else: {})
    )

    vmState.mutateStateDB:
      db.setupAlloc(ctx.alloc)
      db.persist(clearCache = false)

    let res = exec(ctx, vmState, conf.stateReward, header)

    if vmState.hashError.len > 0:
      raise newError(ErrorMissingBlockhash, vmState.hashError)

    ctx.dispatchOutput(conf, res)
