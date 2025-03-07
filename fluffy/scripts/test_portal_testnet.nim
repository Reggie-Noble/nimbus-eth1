# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  os,
  std/sequtils,
  unittest2, testutils, confutils, chronos,
  stew/byteutils,
  eth/p2p/discoveryv5/random2, eth/keys,
  ../../nimbus/rpc/[hexstrings, rpc_types],
  ../rpc/portal_rpc_client,
  ../rpc/eth_rpc_client,
  ../data/[history_data_seeding, history_data_parser],
  ../network/history/[history_content, accumulator],
  ../seed_db

type
  FutureCallback[A] = proc (): Future[A] {.gcsafe, raises: [Defect].}

  CheckCallback[A] = proc (a: A): bool {.gcsafe, raises: [Defect].}

  PortalTestnetConf* = object
    nodeCount* {.
      defaultValue: 17
      desc: "Number of nodes to test"
      name: "node-count" .}: int

    rpcAddress* {.
      desc: "Listening address of the JSON-RPC service for all nodes"
      defaultValue: "127.0.0.1"
      name: "rpc-address" }: string

    baseRpcPort* {.
      defaultValue: 7000
      desc: "Port of the JSON-RPC service of the bootstrap (first) node"
      name: "base-rpc-port" .}: uint16

proc buildHeadersWithProof*(
    blockHeaders: seq[BlockHeader],
    epochAccumulator: EpochAccumulatorCached):
    Result[seq[(seq[byte], seq[byte])], string] =
  var blockHeadersWithProof: seq[(seq[byte], seq[byte])]
  for header in blockHeaders:
    if header.isPreMerge():
      let
        content = ? buildHeaderWithProof(header, epochAccumulator)
        contentKey = ContentKey(
          contentType: blockHeaderWithProof,
          blockHeaderWithProofKey: BlockKey(blockHash: header.blockHash()))

      blockHeadersWithProof.add(
        (encode(contentKey).asSeq(), SSZ.encode(content)))

  ok(blockHeadersWithProof)

proc connectToRpcServers(config: PortalTestnetConf):
    Future[seq[RpcClient]] {.async.} =
  var clients: seq[RpcClient]
  for i in 0..<config.nodeCount:
    let client = newRpcHttpClient()
    await client.connect(
      config.rpcAddress, Port(config.baseRpcPort + uint16(i)), false)
    clients.add(client)

  return clients

proc withRetries[A](
  f: FutureCallback[A],
  check: CheckCallback[A],
  numRetries: int,
  initialWait: Duration,
  checkFailMessage: string,
  nodeIdx: int): Future[A] {.async.} =
  ## Retries given future callback until either:
  ## it returns successfuly and given check is true
  ## or
  ## function reaches max specified retries

  var tries = 0
  var currentDuration = initialWait

  while true:
    try:
      let res = await f()
      if check(res):
        return res
      else:
        raise newException(ValueError, checkFailMessage)
    except CatchableError as exc:
      if tries > numRetries:
        # if we reached max number of retries fail
        let msg = "Call failed with msg: " & exc.msg & ", for node with idx: " & $nodeIdx
        raise newException(ValueError, msg)

    inc tries
    # wait before new retry
    await sleepAsync(currentDuration)
    currentDuration = currentDuration * 2

# Sometimes we need to wait till data will be propagated over the network.
# To avoid long sleeps, this combinator can be used to retry some calls until
# success or until some condition hold (or both)
proc retryUntil[A](
  f: FutureCallback[A],
  c: CheckCallback[A],
  checkFailMessage: string,
  nodeIdx: int): Future[A] =
  # some reasonable limits, which will cause waits as: 1, 2, 4, 8, 16, 32 seconds
  return withRetries(f, c, 1, seconds(1), checkFailMessage, nodeIdx)

# Note:
# When doing json-rpc requests following `RpcPostError` can occur:
# "Failed to send POST Request with JSON-RPC." when a `HttpClientRequestRef`
# POST request is send in the json-rpc http client.
# This error is raised when the httpclient hits error:
# "Could not send request headers", which in its turn is caused by the
# "Incomplete data sent or received" in `AsyncStream`, which is caused by
# `ECONNRESET` or `EPIPE` error (see `isConnResetError()`) on the TCP stream.
# This can occur when the server side closes the connection, which happens after
# a `httpHeadersTimeout` of default 10 seconds (set on `HttpServerRef.new()`).
# In order to avoid here hitting this timeout a `close()` is done after each
# json-rpc call. Because the first json-rpc call opens up the connection, and it
# remains open until a close() (or timeout). No need to do another connect
# before any new call as the proc `connectToRpcServers` doesn't actually connect
# to servers, as client.connect doesn't do that. It just sets the `httpAddress`.
# Yes, this client json rpc API couldn't be more confusing.
# Could also just retry each call on failure, which would set up a new
# connection.


# We are kind of abusing the unittest2 here to run json rpc tests against other
# processes. Needs to be compiled with `-d:unittest2DisableParamFiltering` or
# the confutils cli will not work.
procSuite "Portal testnet tests":
  let config = PortalTestnetConf.load()
  let rng = newRng()

  asyncTest "Discv5 - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.discv5_nodeInfo()
      await client.close()
      nodeInfos.add(nodeInfo)

    # Kick off the network by trying to add all records to each node.
    # These nodes are also set as seen, so they get passed along on findNode
    # requests.
    # Note: The amount of Records added here can be less but then the
    # probability that all nodes will still be reached needs to be calculated.
    # Note 2: One could also ping all nodes but that is much slower and more
    # error prone
    for client in clients:
      discard await client.discv5_addEnrs(nodeInfos.map(
        proc(x: NodeInfo): Record = x.enr))
      await client.close()

    for client in clients:
      let routingTableInfo = await client.discv5_routingTableInfo()
      await client.close()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      # A node will have at least the first bucket filled. One could increase
      # this based on the probability that x amount of nodes fit in the buckets.
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      enr = await client.discv5_lookupEnr(randomNodeInfo.nodeId)
      check enr == randomNodeInfo.enr
      await client.close()

  asyncTest "Portal State - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.portal_state_nodeInfo()
      await client.close()
      nodeInfos.add(nodeInfo)

    for client in clients:
      discard await client.portal_state_addEnrs(nodeInfos.map(
        proc(x: NodeInfo): Record = x.enr))
      await client.close()

    for client in clients:
      let routingTableInfo = await client.portal_state_routingTableInfo()
      await client.close()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      try:
        enr = await client.portal_state_lookupEnr(randomNodeInfo.nodeId)
      except CatchableError as e:
        echo e.msg
      # TODO: For state network this occasionally fails. It might be because the
      # distance function is not used in all locations, or perhaps it just
      # doesn't converge to the target always with this distance function. To be
      # further investigated.
      skip()
      # check enr == randomNodeInfo.enr
      await client.close()

  asyncTest "Portal History - Random node lookup from each node":
    let clients = await connectToRpcServers(config)

    var nodeInfos: seq[NodeInfo]
    for client in clients:
      let nodeInfo = await client.portal_history_nodeInfo()
      await client.close()
      nodeInfos.add(nodeInfo)

    for client in clients:
      discard await client.portal_history_addEnrs(nodeInfos.map(
        proc(x: NodeInfo): Record = x.enr))
      await client.close()

    for client in clients:
      let routingTableInfo = await client.portal_history_routingTableInfo()
      await client.close()
      var start: seq[NodeId]
      let nodes = foldl(routingTableInfo.buckets, a & b, start)
      check nodes.len >= (min(config.nodeCount - 1, 16))

    # grab a random node its `NodeInfo` and lookup that node from all nodes.
    let randomNodeInfo = sample(rng[], nodeInfos)
    for client in clients:
      var enr: Record
      enr = await client.portal_history_lookupEnr(randomNodeInfo.nodeId)
      await client.close()
      check enr == randomNodeInfo.enr

  asyncTest "Portal History - Propagate blocks and do content lookups":
    const
      headerFile = "./vendor/portal-spec-tests/tests/mainnet/history/headers/1000001-1000010.e2s"
      accumulatorFile = "./vendor/portal-spec-tests/tests/mainnet/history/accumulator/epoch-accumulator-00122.ssz"
      blockDataFile = "./fluffy/tests/blocks/mainnet_blocks_1000001_1000010.json"

    let
      blockHeaders = readBlockHeaders(headerFile).valueOr:
        raiseAssert "Invalid header file: " & headerFile
      epochAccumulator = readEpochAccumulatorCached(accumulatorFile).valueOr:
        raiseAssert "Invalid epoch accumulator file: " & accumulatorFile
      blockHeadersWithProof =
        buildHeadersWithProof(blockHeaders, epochAccumulator).valueOr:
          raiseAssert "Could not build headers with proof"
      blockData =
        readJsonType(blockDataFile, BlockDataTable).valueOr:
          raiseAssert "Invalid block data file" & blockDataFile

      clients = await connectToRpcServers(config)

    # Gossiping all block headers with proof first, as bodies and receipts
    # require them for validation.
    for (content, contentKey) in blockHeadersWithProof:
      discard (await clients[0].portal_history_offer(
        content.toHex(), contentKey.toHex()))

    # This will fill the first node its db with blocks from the data file. Next,
    # this node wil offer all these blocks their headers one by one.
    check (await clients[0].portal_history_propagate(blockDataFile))
    await clients[0].close()

    for i, client in clients:
      # Note: Once there is the Canonical Indices Network, we don't need to
      # access this file anymore here for the block hashes.
      for hash in blockData.blockHashes():
        # Note: More flexible approach instead of generic retries could be to
        # add a json-rpc debug proc that returns whether the offer queue is empty or
        # not. And then poll every node until all nodes have an empty queue.
        let content = await retryUntil(
          proc (): Future[Option[BlockObject]] {.async.} =
            try:
              let res = await client.eth_getBlockByHash(hash.ethHashStr(), false)
              await client.close()
              return res
            except CatchableError as exc:
              await client.close()
              raise exc
          ,
          proc (mc: Option[BlockObject]): bool = return mc.isSome(),
          "Did not receive expected Block with hash " & hash.data.toHex(),
          i
        )
        check content.isSome()
        let blockObj = content.get()
        check blockObj.hash.get() == hash

        for tx in blockObj.transactions:
          var txObj: TransactionObject
          tx.fromJson("tx", txObj)
          check txObj.blockHash.get() == hash

        let filterOptions = FilterOptions(
          blockHash: some(hash)
        )

        let logs = await retryUntil(
          proc (): Future[seq[FilterLog]] {.async.} =
            try:
              let res = await client.eth_getLogs(filterOptions)
              await client.close()
              return res
            except CatchableError as exc:
              await client.close()
              raise exc
          ,
          proc (mc: seq[FilterLog]): bool = return true,
          "",
          i
        )

        for l in logs:
          check:
            l.blockHash == some(hash)

        # TODO: Check ommersHash, need the headers and not just the hashes
        # for uncle in blockObj.uncles:
        #   discard

      await client.close()

  asyncTest "Portal History - Propagate content from seed db":
    # Skipping this as it seems to fail now at offerContentInNodeRange, likely
    # due to not being possibly to validate block bodies. This would mean the
    # test is flawed and block headers should be offered before bodies and
    # receipts.
    # TODO: Split this up and activate test
    skip()

    # const
    #   headerFile = "./vendor/portal-spec-tests/tests/mainnet/history/headers/1000011-1000030.e2s"
    #   accumulatorFile = "./vendor/portal-spec-tests/tests/mainnet/history/accumulator/epoch-accumulator-00122.ssz"
    #   blockDataFile = "./fluffy/tests/blocks/mainnet_blocks_1000011_1000030.json"

    #   # Path for the temporary db. A separate dir is used as sqlite usually also
    #   # creates wal files.
    #   tempDbPath = "./fluffy/tests/blocks/tempDir/mainnet_blocks_1000011_1000030.sqlite3"

    # let
    #   blockHeaders = readBlockHeaders(headerFile).valueOr:
    #     raiseAssert "Invalid header file: " & headerFile
    #   epochAccumulator = readEpochAccumulatorCached(accumulatorFile).valueOr:
    #     raiseAssert "Invalid epoch accumulator file: " & accumulatorFile
    #   blockHeadersWithProof =
    #     buildHeadersWithProof(blockHeaders, epochAccumulator).valueOr:
    #       raiseAssert "Could not build headers with proof"
    #   blockData =
    #     readJsonType(blockDataFile, BlockDataTable).valueOr:
    #       raiseAssert "Invalid block data file" & blockDataFile

    #   clients = await connectToRpcServers(config)

    # var nodeInfos: seq[NodeInfo]
    # for client in clients:
    #   let nodeInfo = await client.portal_history_nodeInfo()
    #   await client.close()
    #   nodeInfos.add(nodeInfo)

    # let (dbFile, dbName) = getDbBasePathAndName(tempDbPath).unsafeGet()
    # createDir(dbFile)
    # let db = SeedDb.new(path = dbFile, name = dbName)
    # defer:
    #   db.close()
    #   removeDir(dbFile)

    # # Fill seed db with block headers with proof
    # for (content, contentKey) in blockHeadersWithProof:
    #   let contentId = history_content.toContentId(ByteList(contentKey))
    #   db.put(contentId, contentKey, content)

    # # Fill seed db with block bodies and receipts
    # for t in blocksContent(blockData, false):
    #   db.put(t[0], t[1], t[2])

    # let lastNodeIdx = len(nodeInfos) - 1

    # # Store content in node 0 database
    # check (await clients[0].portal_history_storeContentInNodeRange(
    #   tempDbPath, 100, 0))
    # await clients[0].close()

    # # Offer content to node 1..63
    # for i in 1..lastNodeIdx:
    #   let recipientId = nodeInfos[i].nodeId
    #   let offerResponse = await retryUntil(
    #     proc (): Future[int] {.async.} =
    #       try:
    #         let res = await clients[0].portal_history_offerContentInNodeRange(
    #           tempDbPath, recipientId, 64, 0)
    #         await clients[0].close()
    #         return res
    #       except CatchableError as exc:
    #         await clients[0].close()
    #         raise exc
    #     ,
    #     proc (os: int): bool = return true,
    #     "Offer failed",
    #     i
    #   )
    #   check:
    #     offerResponse > 0

    # for i, client in clients:
    #   # Note: Once there is the Canonical Indices Network, we don't need to
    #   # access this file anymore here for the block hashes.
    #   for hash in blockData.blockHashes():
    #     let content = await retryUntil(
    #       proc (): Future[Option[BlockObject]] {.async.} =
    #         try:
    #           let res = await client.eth_getBlockByHash(hash.ethHashStr(), false)
    #           await client.close()
    #           return res
    #         except CatchableError as exc:
    #           await client.close()
    #           raise exc
    #       ,
    #       proc (mc: Option[BlockObject]): bool = return mc.isSome(),
    #       "Did not receive expected Block with hash " & hash.data.toHex(),
    #       i
    #     )
    #     check content.isSome()

    #     let blockObj = content.get()
    #     check blockObj.hash.get() == hash

    #     for tx in blockObj.transactions:
    #       var txObj: TransactionObject
    #       tx.fromJson("tx", txObj)
    #       check txObj.blockHash.get() == hash

    #   await client.close()

  asyncTest "Portal History - Propagate content from seed db in depth first fashion":
    # Skipping this test as it is flawed considering block headers should be
    # offered before bodies and receipts.
    # TODO: Split this up and activate test
    skip()

    # const
    #   headerFile = "./vendor/portal-spec-tests/tests/mainnet/history/headers/1000011-1000030.e2s"
    #   accumulatorFile = "./vendor/portal-spec-tests/tests/mainnet/history/accumulator/epoch-accumulator-00122.ssz"
    #   # Different set of data for each test as tests are statefull so previously
    #   # propagated content is still in the network
    #   blockDataFile = "./fluffy/tests/blocks/mainnet_blocks_1000040_1000050.json"

    #   # Path for the temporary db. A separate dir is used as sqlite usually also
    #   # creates wal files.
    #   tempDbPath = "./fluffy/tests/blocks/tempDir/mainnet_blocks_1000040_100050.sqlite3"

    # let
    #   blockHeaders = readBlockHeaders(headerFile).valueOr:
    #     raiseAssert "Invalid header file: " & headerFile
    #   epochAccumulator = readEpochAccumulatorCached(accumulatorFile).valueOr:
    #     raiseAssert "Invalid epoch accumulator file: " & accumulatorFile
    #   blockHeadersWithProof =
    #     buildHeadersWithProof(blockHeaders, epochAccumulator).valueOr:
    #       raiseAssert "Could not build headers with proof"
    #   blockData =
    #     readJsonType(blockDataFile, BlockDataTable).valueOr:
    #       raiseAssert "Invalid block data file" & blockDataFile

    #   clients = await connectToRpcServers(config)

    # var nodeInfos: seq[NodeInfo]
    # for client in clients:
    #   let nodeInfo = await client.portal_history_nodeInfo()
    #   await client.close()
    #   nodeInfos.add(nodeInfo)

    # let (dbFile, dbName) = getDbBasePathAndName(tempDbPath).unsafeGet()
    # createDir(dbFile)
    # let db = SeedDb.new(path = dbFile, name = dbName)
    # defer:
    #   db.close()
    #   removeDir(dbFile)

    # # Fill seed db with block headers with proof
    # for (content, contentKey) in blockHeadersWithProof:
    #   let contentId = history_content.toContentId(ByteList(contentKey))
    #   db.put(contentId, contentKey, content)

    # # Fill seed db with block bodies and receipts
    # for t in blocksContent(blockData, false):
    #   db.put(t[0], t[1], t[2])

    # check (await clients[0].portal_history_depthContentPropagate(tempDbPath, 64))
    # await clients[0].close()

    # for i, client in clients:
    #   # Note: Once there is the Canonical Indices Network, we don't need to
    #   # access this file anymore here for the block hashes.
    #   for hash in blockData.blockHashes():
    #     let content = await retryUntil(
    #       proc (): Future[Option[BlockObject]] {.async.} =
    #         try:
    #           let res = await client.eth_getBlockByHash(hash.ethHashStr(), false)
    #           await client.close()
    #           return res
    #         except CatchableError as exc:
    #           await client.close()
    #           raise exc
    #       ,
    #       proc (mc: Option[BlockObject]): bool = return mc.isSome(),
    #       "Did not receive expected Block with hash " & hash.data.toHex(),
    #       i
    #     )
    #     check content.isSome()

    #     let blockObj = content.get()
    #     check blockObj.hash.get() == hash

    #     for tx in blockObj.transactions:
    #       var txObj: TransactionObject
    #       tx.fromJson("tx", txObj)
    #       check txObj.blockHash.get() == hash

    #   await client.close()
