# frozen_string_literal: true

module CKB
  class OutputGroup
    attr_reader :outputs, :fee, :value, :effective_value, :long_term_fee

    def initialize(outputs, fee_rate)
      @outputs = outputs
      @fee = calculate_fee(outputs.size)
      @value = @outputs.map { |output| output.capacity }.reduce(&:+)
      @effective_value = @value - @fee
      raise "value: #{value} is less than fee: #{fee}" if @value < @fee
      # what's long_term_fee ?
      @long_term_fee = 0
    end

    # suppose all outputs are sign with secp
    def calculate_fee(outputs_size)
      (TransactionSize.every_input + TransactionSize.every_secp_witness) * outputs_size
    end
  end

  class CoinSelection
    TOTAL_TRIES = 100_000
    COIN = 100_000_000

    MAX_MONEY = 336 * 10**8 * COIN

    # @param change_output [CKB::Types::Output]
    # @param change_output_data [String] 0x...
    # @param fee_rate [Integer]
    def calculate_change_output_fee(change_output, change_output_data, fee_rate)
      # size of change_output: output / output_data / input / witness
      size = TransactionSize.every_output(change_output) +
               TransactionSize.every_outputs_data(change_output_data) +
               TransactionSize.every_input +
               TransactionSize.every_secp_witness

      Types::Transaction.fee(size, fee_rate)
    end

    def calculate_fixed_fee(cell_deps_size, header_deps_size, outputs, outputs_data, fee_rate)
      size = TransactionSize.every_cell_dep * cell_deps_size +
             TransactionSize.every_header_dep * header_deps_size +
             outputs.map { |output| TransactionSize.every_output(output) }.reduce(:+) +
             outputs_data.map { |data| TransactionSize.every_outputs_data(data) }.reduce(:+)

      Types::Transaction.fee(size, fee_rate)
    end

    # see https://github.com/bitcoin/bitcoin/blob/master/src/wallet/coinselection.cpp#L21 for more details
    #
    # The Branch and Bound Coin Selection algorithm designed by Murch
    #
    # @param utxo_pool [CKB::CoinSelection::OutputGroup] The set of OutputGroups that we are choosing from. These OutputGroups will be sorted in descending order by effective value
    # @param target_value [Integer] This is the value that we want to select. It is the lower bound of the range.
    # @param cost_of_change [Integer] This is the cost of creating and spending a change output. This plus target_value is the upper bound of the range.
    # @param not_input_fees [Integer] The fees that need to be paid for the outputs and fixed size overhead
    #
    # @return [[bool, CKB::CoinSelection::OutputGroup[], Integer]]
    def select_coins_bnb(utxo_pool, target_value, cost_of_change, not_input_fees)
      # This is for the set of OutputGroups that have been selected.
      out_set = []
      # This is for the total value of OutputGroups the were selected.
      value_ret = 0
      curr_value = 0

      curr_selection = []
      actual_target = not_input_fees + target_value

      # Calculate curr_available_value
      curr_available_value = utxo_pool.map { |output_group| output_group.effective_value }.reduce(:+)

      if curr_available_value < actual_target
        return {
          result: false,
          out_set: out_set,
          value_ret: value_ret,
        }
      end

      # sort the utxo_pool, big to small
      utxo_pool.sort! { |u1, u2| u2.effective_value <=> u1.effective_value }

      curr_waste = 0
      best_selection = []
      best_waste = MAX_MONEY

      TOTAL_TRIES.times.each do |i|
        backtrack = false

        if (curr_value + curr_available_value < actual_target ||
           curr_value > actual_target + cost_of_change ||
           (curr_waste > best_waste && utxo_pool.first.fee > utxo.first.long_term_fee)
        )
          backtrack = true
        elsif curr_value >= actual_target
          curr_waste += curr_value - actual_target
          if curr_waste <= best_waste
            best_selection = curr_selection
            best_selection.fill(best_selection.size, utxo_pool.size - best_selection.size) { false }
            best_waste = curr_waste
          end
          curr_waste -= (curr_value - actual_target)
          backtrack = true
        end

        # backtracking, moving backwards
        if backtrack
          # Walk backwards to find the last included Output that still needs to have its omission branch traversed.
          while !curr_selection.empty? && !curr_selection.last
            curr_selection.pop
            curr_available_value += utxo_pool[curr_selection.size].effective_value
          end

          break if curr_selection.empty?

          curr_selection[curr_selection.size - 1] = false
          output_group = utxo_pool[curr_selection.size - 1]
          curr_value -= output_group.effective_value
          curr_waste -= output_group.fee - output_group.long_term_fee
        else
          # moving forwards, continuing down this branch
          output_group = utxo_pool[curr_selection.size]
          curr_available_value -= output_group.effective_value

          if !curr_selection.empty? &&
            !curr_selection.last &&
            output_group.effective_value == utxo_pool[curr_selection.size - 1].effective_value &&
            output_group.fee == utxo_pool[curr_selection.size - 1].fee
            curr_selection << false
          else
            curr_selection << true
            curr_value += output_group.effective_value
            curr_waste += output_group.fee - output_group.long_term_fee
          end
        end
      end

      if best_selection.empty?
        return {
          result: false,
          out_set: out_set,
          value_ret: value_ret
        }
      end

      value_ret = 0
      best_selection.each.with_index do |selection, i|
        if selection
          output_group = utxo_pool[i]
          out_set += output_group.outputs
          value_ret = output_group.value
        end
      end

      return {
        result: true,
        out_set: out_set,
        value_ret: value_ret
      }
    end
  end
end
