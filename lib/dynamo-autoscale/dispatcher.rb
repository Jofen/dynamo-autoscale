module DynamoAutoscale
  class Dispatcher
    def initialize
      @last_check = {}
    end

    def dispatch table, time, datum, &block
      DynamoAutoscale.current_table = table
      logger.debug "#{time}: Dispatching to #{table.name} with data: #{datum}"

      if datum[:provisioned_reads] and (datum[:consumed_reads] > datum[:provisioned_reads])
        lost_reads = datum[:consumed_reads] - datum[:provisioned_reads]

        logger.warn "[reads ] Lost units: #{lost_reads} " +
          "(#{datum[:consumed_reads]} - #{datum[:provisioned_reads]})"
      end

      if datum[:provisioned_writes] and (datum[:consumed_writes] > datum[:provisioned_writes])
        lost_writes = datum[:consumed_writes] - datum[:provisioned_writes]

        logger.warn "[writes] Lost units: #{lost_writes} " +
          "(#{datum[:consumed_writes]} - #{datum[:provisioned_writes]})"
      end

      table.tick(time, datum)
      block.call(table, time, datum) if block

      if @last_check[table.name].nil? or @last_check[table.name] < time
        DynamoAutoscale.rules.test(table)
        @last_check[table.name] = time
      else
        logger.debug "#{table.name}: Skipped rule check, already checked for " +
          "a later data point."
      end

      DynamoAutoscale.current_table = nil
    end
  end
end
