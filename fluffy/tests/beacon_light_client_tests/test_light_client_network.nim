# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[os, typetraits],
  testutils/unittests, chronos,
  eth/p2p/discoveryv5/protocol as discv5_protocol, eth/p2p/discoveryv5/routing_table,
  eth/common/eth_types_rlp,
  eth/rlp,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/altair,
  ../../network/wire/[portal_protocol, portal_stream],
  ../../network/beacon_light_client/[light_client_network, light_client_content],
  ../../../nimbus/constants,
  "."/[light_client_test_data, light_client_test_helpers]

procSuite "Light client Content Network":
  let rng = newRng()

  asyncTest "Get bootstrap by trusted block hash":
    let
      lcNode1 = newLCNode(rng, 20302)
      lcNode2 = newLCNode(rng, 20303)
      forks = getTestForkDigests()

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      bootstrap = SSZ.decode(bootstrapBytes, altair.LightClientBootstrap)
      bootstrappHeaderHash = hash_tree_root(bootstrap.header)
      bootstrapKey = LightClientBootstrapKey(
        blockHash: bootstrappHeaderHash
      )
      bootstrapContentKey = ContentKey(
        contentType: lightClientBootstrap,
        lightClientBootstrapKey: bootstrapKey
      )

      bootstrapContentKeyEncoded = encode(bootstrapContentKey)
      bootstrapContentId = toContentId(bootstrapContentKeyEncoded)

    lcNode2.portalProtocol().storeContent(
      bootstrapContentKeyEncoded,
      bootstrapContentId,
      encodeBootstrapForked(forks.altair, bootstrap)
    )

    let bootstrapFromNetworkResult =
      await lcNode1.lightClientNetwork.getLightClientBootstrap(
        bootstrappHeaderHash
      )

    check:
      bootstrapFromNetworkResult.isOk()
      bootstrapFromNetworkResult.get() == bootstrap

    await lcNode1.stop()
    await lcNode2.stop()

  asyncTest "Get latest optimistic and finality updates":
    let
      lcNode1 = newLCNode(rng, 20302)
      lcNode2 = newLCNode(rng, 20303)
      forks = getTestForkDigests()

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      finalityUpdate = SSZ.decode(lightClientFinalityUpdateBytes, altair.LightClientFinalityUpdate)
      finalHeaderSlot = finalityUpdate.finalized_header.slot
      finaloptimisticHeaderSlot = finalityUpdate.attested_header.slot
      optimisticUpdate = SSZ.decode(lightClientOptimisticUpdateBytes, altair.LightClientOptimisticUpdate)
      optimisticHeaderSlot = optimisticUpdate.attested_header.slot

      finalityUpdateKey = finalityUpdateContentKey(
        distinctBase(finalHeaderSlot),
        distinctBase(finaloptimisticHeaderSlot)
      )
      finalityKeyEnc = encode(finalityUpdateKey)
      finalityUdpateId = toContentId(finalityKeyEnc)
      optimistUpdateKey = optimisticUpdateContentKey(distinctBase(optimisticHeaderSlot))
      optimisticKeyEnc = encode(optimistUpdateKey)
      optimisticUpdateId = toContentId(optimisticKeyEnc)


    # This silently assumes that peer stores only one latest update, under
    # the contentId coresponding to latest update content key
    lcNode2.portalProtocol().storeContent(
      finalityKeyEnc,
      finalityUdpateId,
      encodeFinalityUpdateForked(forks.altair, finalityUpdate)
    )

    lcNode2.portalProtocol().storeContent(
      optimisticKeyEnc,
      optimisticUpdateId,
      encodeOptimisticUpdateForked(forks.altair, optimisticUpdate)
    )

    let
      finalityResult = await lcNode1.lightClientNetwork.getLightClientFinalityUpdate(
        distinctBase(finalHeaderSlot) - 1,
        distinctBase(finaloptimisticHeaderSlot) - 1
      )
      optimisticResult = await lcNode1.lightClientNetwork.getLightClientOptimisticUpdate(
        distinctBase(optimisticHeaderSlot) - 1
      )

    check:
      finalityResult.isOk()
      optimisticResult.isOk()
      finalityResult.get() == finalityUpdate
      optimisticResult.get() == optimisticUpdate

    await lcNode1.stop()
    await lcNode2.stop()

  asyncTest "Get range of light client updates":
    let
      lcNode1 = newLCNode(rng, 20302)
      lcNode2 = newLCNode(rng, 20303)
      forks = getTestForkDigests()

    check:
      lcNode1.portalProtocol().addNode(lcNode2.localNode()) == Added
      lcNode2.portalProtocol().addNode(lcNode1.localNode()) == Added

      (await lcNode1.portalProtocol().ping(lcNode2.localNode())).isOk()
      (await lcNode2.portalProtocol().ping(lcNode1.localNode())).isOk()

    let
      update1 = SSZ.decode(lightClientUpdateBytes, altair.LightClientUpdate)
      update2 = SSZ.decode(lightClientUpdateBytes1, altair.LightClientUpdate)
      updates = @[update1, update2]
      content = encodeLightClientUpdatesForked(forks.altair, updates)
      startPeriod = update1.attested_header.slot.sync_committee_period
      contentKey = ContentKey(
        contentType: lightClientUpdate,
        lightClientUpdateKey: LightClientUpdateKey(
          startPeriod: startPeriod.uint64,
          count: uint64(2)
        )
      )
      contentKeyEncoded = encode(contentKey)
      contentId = toContentId(contentKey)

    lcNode2.portalProtocol().storeContent(
      contentKeyEncoded,
      contentId,
      content
    )

    let updatesResult =
      await lcNode1.lightClientNetwork.getLightClientUpdatesByRange(
        startPeriod.uint64,
        uint64(2)
      )

    check:
      updatesResult.isOk()

    let updatesFromPeer = updatesResult.get()

    check:
      updatesFromPeer == updates

    await lcNode1.stop()
    await lcNode2.stop()
