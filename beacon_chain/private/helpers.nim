# beacon_chain
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Helper functions
import ../datatypes, sequtils, nimcrypto, math

func get_active_validator_indices(validators: openArray[ValidatorRecord]): seq[Uint24] =
  ## Select the active validators
  result = @[]
  for idx, val in validators:
    if val.status == ACTIVE:
      result.add idx.Uint24

func shuffle*[T](values: seq[T], seed: Blake2_256_Digest): seq[T] =
  ## Returns the shuffled ``values`` with seed as entropy.
  ## TODO: this calls out for tests, but I odn't particularly trust spec
  ## right now.

  let values_count = values.len

  const
    # Entropy is consumed from the seed in 3-byte (24 bit) chunks.
    rand_bytes = 3
    # The highest possible result of the RNG.
    rand_max = 2^(rand_bytes * 8) - 1

  # The range of the RNG places an upper-bound on the size of the list that
  # may be shuffled. It is a logic error to supply an oversized list.
  assert values_count < rand_max

  result = values
  var
    source = seed
    index = 0
  while index < values_count - 1:
    # Re-hash the `source` to obtain a new pattern of bytes.
    source = blake2_256.digest source.data
    # Iterate through the `source` bytes in 3-byte chunks.
    for pos in countup(0, 29, 3):
      let remaining = values_count - index
      if remaining == 1:
        break

      # Read 3-bytes of `source` as a 24-bit big-endian integer.
      let sample_from_source =
        source.data[pos].Uint24 shl 16 or
        source.data[pos+1].Uint24 shl 8 or
        source.data[pos+2].Uint24

      # Sample values greater than or equal to `sample_max` will cause
      # modulo bias when mapped into the `remaining` range.
      let sample_max = rand_max - rand_max mod remaining

      # Perform a swap if the consumed entropy will not cause modulo bias.
      if sample_from_source < sample_max:
        # Select a replacement index for the current index.
        let replacement_position = sample_from_source mod remaining + index
        swap result[index], result[replacement_position]
        inc index

func split*[T](lst: openArray[T], N: Positive): seq[seq[T]] =
  # TODO: implement as an iterator
  result = newSeq[seq[T]](N)
  for i in 0 ..< N:
    result[i] = lst[lst.len * i div N ..< lst.len * (i+1) div N] # TODO: avoid alloc via toOpenArray

func get_new_shuffling*(seed: Blake2_256_Digest,
                        validators: openArray[ValidatorRecord],
                        crosslinking_start_shard: int
                        ): seq[seq[ShardAndCommittee]] =
  ## Split up validators into groups at the start of every epoch,
  ## determining at what height they can make attestations and what shard they are making crosslinks for
  ## Implementation should do the following: http://vitalik.ca/files/ShuffleAndAssign.png

  let
    active_validators = get_active_validator_indices(validators)
    committees_per_slot = clamp(
      len(active_validators) div CYCLE_LENGTH div TARGET_COMMITTEE_SIZE,
      1, SHARD_COUNT div CYCLE_LENGTH)
    # Shuffle with seed
    shuffled_active_validator_indices = shuffle(active_validators, seed)
    # Split the shuffled list into cycle_length pieces
    validators_per_slot = split(shuffled_active_validator_indices, CYCLE_LENGTH)

  for slot, slot_indices in validators_per_slot:
    let
      shard_indices = split(slot_indices, committees_per_slot)
      shard_id_start = crosslinking_start_shard + slot * committees_per_slot

    var committees = newSeq[ShardAndCommittee](shard_indices.len)
    for shard_position, indices in shard_indices:
      committees[shard_position].shard_id = (shard_id_start + shard_position).uint16 mod SHARD_COUNT
      committees[shard_position].committee = indices

    result.add committees

func get_shards_and_committees_for_slot*(state: BeaconState,
                                         slot: uint64
                                         ): seq[ShardAndCommittee] =
  # TODO: Spec why is active_state an argument?
  # TODO: this returns a scalar, not vector, but its return type in spec is a seq/list?

  let earliest_slot_in_array = state.last_state_recalculation_slot - CYCLE_LENGTH
  assert earliest_slot_in_array <= slot
  assert slot < earliest_slot_in_array + CYCLE_LENGTH * 2

  return state.shard_and_committee_for_slots[int slot - earliest_slot_in_array]
  # TODO, slot is a uint64; will be an issue on int32 arch.
  #       Clarify with EF if light clients will need the beacon chain

func get_block_hash*(state: BeaconState, current_block: BeaconBlock, slot: int): Blake2_256_Digest =
  let earliest_slot_in_array = current_block.slot.int - state.recent_block_hashes.len
  assert earliest_slot_in_array <= slot
  assert slot < current_block.slot.int

  return state.recent_block_hashes[slot - earliest_slot_in_array]

func get_new_recent_block_hashes*(old_block_hashes: seq[Blake2_256_Digest],
                                  parent_slot, current_slot: int64,
                                  parent_hash: Blake2_256_Digest
                                  ): seq[Blake2_256_Digest] =

  # Should throw for `current_slot - CYCLE_LENGTH * 2 - 1` according to spec comment
  let d = current_slot - parent_slot
  result = old_block_hashes[d .. ^1]
  for _ in 0 ..< min(d, old_block_hashes.len):
    result.add parent_hash

func get_beacon_proposer*(state: BeaconState, slot: uint64): ValidatorRecord =
  let
    first_committee = get_shards_and_committees_for_slot(state, slot)[0].committee
    index = first_committee[(slot mod len(first_committee).uint64).int]
  state.validators[index]
