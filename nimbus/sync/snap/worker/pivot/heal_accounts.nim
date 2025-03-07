# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Heal accounts DB:
## =================
##
## This module is a variation of the `swap-in` module in the sense that it
## searches for missing nodes in the database (which means that links to
## that nodes must exist for knowing this fact) and then fetches the nodes
## from the network.
##
## Algorithm
## ---------
##
## * Run `swapInAccounts()` so that inheritable sub-tries are imported from
##   previous pivots.
##
## * Find nodes with envelopes that have no account in common with any range
##   interval of the `processed` set of the current pivot. Stop if there are
##   no such nodes.
##
## * Extract the missing nodes from the previous step, i.e. the nodes that
##   are known to exist but are not allocated. If all nodes are allocated,
##   employ the `hexaryInspect()` function in a limited mode do find dangling
##   (i.e. missing) sub-nodes of these allocated nodes. Stop if this function
##   fails to find any such nodes.
##
## * From the nodes of the previous step, extract non-allocated nodes and
##   fetch them from the network.
##
## * Install that nodes from the network.
##
## * Rinse and repeat
##
## Discussion:
## -----------
##
## The worst case scenario in the third step might also be solved by allocating
## more accounts and running this healing algorith again.
##
## Due to its potentially poor performance there is no way to recursively
## search the whole database hexary trie for more dangling nodes using the
## `hexaryInspect()` function.
##
import
  std/[math, sequtils, tables],
  chronicles,
  chronos,
  eth/[common, p2p, trie/nibbles, trie/trie_defs, rlp],
  stew/[byteutils, interval_set, keyed_queue],
  ../../../../utils/prettify,
  "../../.."/[sync_desc, types],
  "../.."/[constants, range_desc, worker_desc],
  ../com/[com_error, get_trie_nodes],
  ../db/[hexary_desc, hexary_envelope, hexary_error, hexary_inspect,
         snapdb_accounts],
  ./swap_in

{.push raises: [Defect].}

logScope:
  topics = "snap-heal"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Accounts healing " & info

proc `$`(node: NodeSpecs): string =
  node.partialPath.toHex

proc `$`(rs: NodeTagRangeSet): string =
  rs.fullFactor.toPC(0)

proc `$`(iv: NodeTagRange): string =
  iv.fullFactor.toPC(3)

proc toPC(w: openArray[NodeSpecs]; n: static[int] = 3): string =
  let sumUp = w.mapIt(it.hexaryEnvelope.len).foldl(a+b, 0.u256)
  (sumUp.to(float) / (2.0^256)).toPC(n)

proc healingCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string =
  let ctx = buddy.ctx
  "{" &
    "pivot=" & "#" & $env.stateHeader.blockNumber & "," &
    "nAccounts=" & $env.nAccounts & "," &
    ("covered=" & $env.fetchAccounts.processed & "/" &
                  $ctx.data.coveredAccounts ) & "}"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template discardRlpError(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    discard

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops " & info & ": name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc compileMissingNodesList(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): seq[NodeSpecs] =
  ## Find some missing glue nodes in current database to be fetched
  ## individually.
  let
    ctx = buddy.ctx
    rootKey = env.stateHeader.stateRoot.to(NodeKey)
    getFn = ctx.data.snapDb.getAccountFn
    fa = env.fetchAccounts

  # Import from earlier run
  while buddy.swapInAccounts(env) != 0:
    discard

  var nodes: seq[NodeSpecs]
  noExceptionOops("getMissingNodesList"):
    # Get unallocated nodes to be fetched
    let rc = fa.processed.hexaryEnvelopeDecompose(rootKey, getFn)
    if rc.isOk:
      nodes = rc.value

      # Remove allocated nodes
      let missingNodes = nodes.filterIt(it.nodeKey.ByteArray32.getFn().len == 0)
      if 0 < missingNodes.len:
        when extraTraceMessages:
          trace logTxt "missing nodes", ctx=buddy.healingCtx(env),
             nResult=missingNodes.len, result=missingNodes.toPC
        return missingNodes

  # Plan B, carefully employ `hexaryInspect()`
  if 0 < nodes.len:
    try:
      let stats = getFn.hexaryInspectTrie(
        rootKey, nodes.mapIt(it.partialPath), suspendAfter=healInspectionBatch)
      if 0 < stats.dangling.len:
        trace logTxt "missing nodes (plan B)", ctx=buddy.healingCtx(env),
          nResult=stats.dangling.len, result=stats.dangling.toPC
        return stats.dangling
    except:
      discard


proc fetchMissingNodes(
    buddy: SnapBuddyRef;
    missingNodes: seq[NodeSpecs];
    env: SnapPivotRef;
      ): Future[seq[NodeSpecs]]
      {.async.} =
  ## Extract from `nodes.missing` the next batch of nodes that need
  ## to be merged it into the database
  let
    ctx = buddy.ctx
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot
    pivot = "#" & $env.stateHeader.blockNumber # for logging

    nMissingNodes= missingNodes.len
    nFetchNodes = max(0, nMissingNodes - snapRequestTrieNodesFetchMax)

    # There is no point in fetching too many nodes as it will be rejected. So
    # rest of the `missingNodes` list is ignored to be picked up later.
    fetchNodes = missingNodes[0 ..< nFetchNodes]

  # Initalise for fetching nodes from the network via `getTrieNodes()`
  var
    nodeKey: Table[Blob,NodeKey] # Temporary `path -> key` mapping
    pathList: seq[seq[Blob]]     # Function argument for `getTrieNodes()`
  for w in fetchNodes:
    pathList.add @[w.partialPath]
    nodeKey[w.partialPath] = w.nodeKey

  # Fetch nodes from the network.
  let rc = await buddy.getTrieNodes(stateRoot, pathList, pivot)
  if rc.isOk:
    # Reset error counts for detecting repeated timeouts, network errors, etc.
    buddy.data.errors.resetComError()

    # Forget about unfetched missing nodes, will be picked up later
    return rc.value.nodes.mapIt(NodeSpecs(
      partialPath: it.partialPath,
      nodeKey:     nodeKey[it.partialPath],
      data:        it.data))

  # Process error ...
  let
    error = rc.error
    ok = await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors)
  when extraTraceMessages:
    if ok:
      trace logTxt "fetch nodes error => stop", peer,
        ctx=buddy.healingCtx(env), error
    else:
      trace logTxt "fetch nodes error", peer,
        ctx=buddy.healingCtx(env), error

  return @[]


proc kvAccountLeaf(
    buddy: SnapBuddyRef;
    node: NodeSpecs;
    env: SnapPivotRef;
      ): (bool,NodeKey,Account) =
  ## Re-read leaf node from persistent database (if any)
  let
    peer = buddy.peer
  var
    nNibbles = -1

  discardRlpError("kvAccountLeaf"):
    let
      nodeRlp = rlpFromBytes node.data
      prefix = (hexPrefixDecode node.partialPath)[1]
      segment = (hexPrefixDecode nodeRlp.listElem(0).toBytes)[1]
      nibbles = prefix & segment

    nNibbles = nibbles.len
    if nNibbles == 64:
      let
        data = nodeRlp.listElem(1).toBytes
        nodeKey = nibbles.getBytes.convertTo(NodeKey)
        accData = rlp.decode(data,Account)
      return (true, nodeKey, accData)

  when extraTraceMessages:
    trace logTxt "non-leaf node path or corrupt data", peer,
      ctx=buddy.healingCtx(env), nNibbles


proc registerAccountLeaf(
    buddy: SnapBuddyRef;
    accKey: NodeKey;
    acc: Account;
    env: SnapPivotRef;
      ) =
  ## Process single account node as would be done with an interval by
  ## the `storeAccounts()` function
  let
    peer = buddy.peer
    pt = accKey.to(NodeTag)

  # Register isolated leaf node
  if 0 < env.fetchAccounts.processed.merge(pt,pt) :
    env.nAccounts.inc
    env.fetchAccounts.unprocessed.reduce(pt,pt)
    discard buddy.ctx.data.coveredAccounts.merge(pt,pt)

    # Update storage slots batch
    if acc.storageRoot != emptyRlpHash:
      env.fetchStorageFull.merge AccountSlotsHeader(
        acckey:      accKey,
        storageRoot: acc.storageRoot)

# ------------------------------------------------------------------------------
# Private functions: do the healing for one round
# ------------------------------------------------------------------------------

proc accountsHealingImpl(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): Future[int]
      {.async.} =
  ## Fetching and merging missing account trie database nodes. It returns the
  ## number of nodes fetched from the network, and -1 upon error.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    fa = env.fetchAccounts

    # Update for changes since last visit
    missingNodes = buddy.compileMissingNodesList(env)

  if missingNodes.len == 0:
    # Nothing to do
    trace logTxt "nothing to do", peer, ctx=buddy.healingCtx(env)
    return 0 # nothing to do

  # Get next batch of nodes that need to be merged it into the database
  let fetchedNodes = await buddy.fetchMissingNodes(missingNodes, env)
  if fetchedNodes.len == 0:
    return 0

  # Store nodes onto disk
  let
    nFetchedNodes = fetchedNodes.len
    report = db.importRawAccountsNodes(peer, fetchedNodes)

  if 0 < report.len and report[^1].slot.isNone:
    # Storage error, just run the next lap (not much else that can be done)
    error logTxt "error updating persistent database", peer,
      ctx=buddy.healingCtx(env), nFetchedNodes, error=report[^1].error
    return -1

  # Filter out error and leaf nodes
  var
    nIgnored = 0
    nLeafNodes = 0 # for logging
  for w in report:
    if w.slot.isSome: # non-indexed entries appear typically at the end, though
      let inx = w.slot.unsafeGet

      if w.kind.isNone:
        # Error report without node referenece
        discard

      elif w.error != NothingSerious:
        # Node error, will need to pick up later and download again
        nIgnored.inc

      elif w.kind.unsafeGet == Leaf:
        # Leaf node has been stored, double check
        let (isLeaf, key, acc) = buddy.kvAccountLeaf(fetchedNodes[inx], env)
        if isLeaf:
          # Update `unprocessed` registry, collect storage roots (if any)
          buddy.registerAccountLeaf(key, acc, env)
          nLeafNodes.inc

  when extraTraceMessages:
    trace logTxt "merged into database", peer,
      ctx=buddy.healingCtx(env), nFetchedNodes, nLeafNodes

  return nFetchedNodes - nIgnored

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc healAccounts*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetching and merging missing account trie database nodes.
  let
    ctx = buddy.ctx
    peer = buddy.peer

  when extraTraceMessages:
    trace logTxt "started", peer, ctx=buddy.healingCtx(env)

  var
    nNodesFetched = 0
    nFetchLoop = 0
  # Stop after `healAccountsBatchFetchMax` nodes have been fetched
  while nNodesFetched < healAccountsBatchFetchMax:
    var nNodes = await buddy.accountsHealingImpl(env)
    if nNodes <= 0:
      break
    nNodesFetched.inc(nNodes)
    nFetchLoop.inc

  when extraTraceMessages:
    trace logTxt "job done", peer, ctx=buddy.healingCtx(env),
      nNodesFetched, nFetchLoop, runState=buddy.ctrl.state

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
