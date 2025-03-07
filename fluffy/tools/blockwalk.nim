# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Testing tool to verify that a specific range of blocks can be fetched from
# the Portal network.

{.push raises: [Defect].}

import
  std/strutils,
  confutils, chronicles, chronicles/topics_registry, stew/byteutils,
  eth/common/eth_types,
  ../../nimbus/rpc/[hexstrings, rpc_types], ../../nimbus/errors,
  ../rpc/eth_rpc_client

type
  BlockWalkConf* = object
    logLevel* {.
      defaultValue: LogLevel.INFO
      defaultValueDesc: $LogLevel.INFO
      desc: "Sets the log level"
      name: "log-level" .}: LogLevel

    rpcAddress* {.
      desc: "Address of the JSON-RPC service"
      defaultValue: "127.0.0.1"
      name: "rpc-address" .}: string

    rpcPort* {.
      defaultValue: 8545
      desc: "Port of the JSON-RPC service"
      name: "rpc-port" .}: uint16

    blockHash* {.
      desc: "The block hash from where to start walking the blocks backwards"
      name: "block-hash" .}: Hash256

proc parseCmdArg*(T: type Hash256, p: TaintedString): T
    {.raises: [Defect, ConfigurationError].} =
  var hash: Hash256
  try:
    hexToByteArray(p, hash.data)
  except ValueError:
    raise newException(ConfigurationError, "Invalid Hash256")

  return hash

proc completeCmdArg*(T: type Hash256, val: TaintedString): seq[string] =
  return @[]

proc walkBlocks(client: RpcClient, startHash: Hash256) {.async.} =
  var parentHash = startHash
  var blockNumber = ""

  # Should be 0x0, but block 0 does not exist in the json data file
  while blockNumber != "0x1":
    let parentBlockOpt =
      try:
        await client.eth_getBlockByHash(parentHash.ethHashStr(), false)
      except RpcPostError as e:
        # RpcPostError when for example timing out on the request. Could retry
        # in this case.
        fatal "Error occured on JSON-RPC request", error = e.msg
        quit 1
      except ValidationError as e:
        # ValidationError from buildBlockObject, should not occur with proper
        # blocks
        fatal "Error occured on JSON-RPC request", error = e.msg
        quit 1

    # Using the http connection re-use seems to slow down these sequentual
    # requests considerably. Force a new connection setup by doing a close after
    # each request.
    await client.close()

    if parentBlockOpt.isNone():
      fatal "Failed getting parent block", hash = parentHash.data.toHex()
      quit 1

    let parentBlock = parentBlockOpt.get()
    if parentBlock.number.isNone() or parentBlock.hash.isNone():
      fatal "Parent block cannot be a pending block",
        hash = parentHash.data.toHex()
      quit 1

    blockNumber = parentBlock.number.get().string
    parentHash = parentBlock.parentHash

    echo "Block " & $blockNumber.parseHexInt() & ": " &
      parentBlock.hash.get().data.toHex()

proc run(config: BlockWalkConf) {.async.} =
  let client = newRpcHttpClient()
  await client.connect(config.rpcAddress, Port(config.rpcPort), false)

  await walkBlocks(client, config.blockHash)

when isMainModule:
  {.pop.}
  let config = BlockWalkConf.load()
  {.push raises: [Defect].}

  setLogLevel(config.logLevel)

  waitFor run(config)
