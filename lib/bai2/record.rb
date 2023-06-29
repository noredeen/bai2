require 'bai2/parser'
require 'bai2/type-code-data.rb'

require 'time'

module Bai2

  # This class represents a record. It knows how to parse the single record
  # information, but has no knowledge of the structure of the file.
  #
  class Record

    RECORD_CODES = {'01' => :file_header,
                    '02' => :group_header,
                    '03' => :account_identifier,
                    '16' => :transaction_detail,
                    '49' => :account_trailer,
                    '88' => :continuation,
                    '98' => :group_trailer,
                    '99' => :file_trailer }


    # These parsing blocks are used below for the special date format BAI2 uses.
    # Assumes UTC, because we do not have timezone information.

    # Returns a date object
    ParseDate = ->(v) do
      Time.strptime("#{v} utc", '%y%m%d %Z')
    end

    # Returns a time interval in seconds, to be added to the date
    ParseMilitaryTime = -> (v) do
      v = '2400' if (v == '' || v == '9999')
      Time.strptime("#{v} utc", '%H%M %Z').to_i % 86400
    end

    # Parses a type code, returns a structured informative hash
    ParseTypeCode = -> (code) do
      meaning = TypeCodeData[code.to_i] || [nil, nil, nil]
      {
        code:        code.to_i,
        transaction: meaning[0],
        scope:       meaning[1],
        description: meaning[2],
      }
    end

    # Cleans up text in continuations, removing leading commas
    CleanContinuedText = -> (text) do
      text.gsub(/,?,\n/, "\n").gsub(/^\n/, '')
    end

    # This block ensures that only version 2 of the BAI standard is accepted
    AssertVersion2 = ->(v) do
      unless v == "2"
        raise ParseError.new("Unsupported BAI version (#{v} != 2)")
      end
      v.to_i
    end

    # For each record code, this defines a simple way to automatically parse the
    # fields. Each field has a list of the keys. Some keys are not simply string
    # types, in which case they will be formatted as a tuple (key, fn), where fn
    # is a block (or anything that responds to `to_proc`) that will be called to
    # cast the value (e.g. `:to_i`).
    #
    SIMPLE_FIELD_MAP = {
      file_header: [
        :record_code,
        :sender,
        :receiver,
        [:file_creation_date, ParseDate],
        [:file_creation_time, ParseMilitaryTime],
        :file_identification_number,
        [:physical_record_length, :to_i],
        [:block_size, :to_i],
        [:version_number, AssertVersion2],
      ],
      group_header: [
        :record_code,
        :destination,
        :originator,
        :group_status,
        [:as_of_date, ParseDate],
        [:as_of_time, ParseMilitaryTime],
        :currency_code,
        :as_of_date_modifier,
      ],
      group_trailer: [
        :record_code,
        [:group_control_total, :to_i],
        [:number_of_accounts, :to_i],
        [:number_of_records, :to_i],
      ],
      account_trailer: [
        :record_code,
        [:account_control_total, :to_i],
        [:number_of_records, :to_i],
      ],
      file_trailer: [
        :record_code,
        [:file_control_total, :to_i],
        [:number_of_groups, :to_i],
        [:number_of_records, :to_i],
      ],
      continuation: [ # TODO: could continue any record at any point...
        :record_code,
        :continuation,
      ],
      # NOTE: transaction_detail is not present here, because it is too complex
      # for a simple mapping like this.
    }


    def initialize(line, physical_record_count = 1, options: {})
      @code = RECORD_CODES[line[0..1]]
      @physical_record_count = physical_record_count
      # clean / delimiter
      @raw = if options[:continuations_slash_delimit_end_of_line_only]
              # Continuation records for transaction details extend the text fields
              # and they may begin with 88,/ but should include the rest of the line.
              # A proper fix would involve each continuation record knowing what field it was extending.
              line.sub(/\/$/, '')
             else
              line.sub(/,\/.+$/, '').sub(/\/$/, '')
             end
    end

    attr_reader :code, :raw, :physical_record_count

    # NOTE: fields is called upon first use, so as not to parse records right
    # away in case they might be merged with a continuation.
    #
    def fields
      @fields ||= parse_raw(@code, @raw, 0)
    end

    # A record can be accessed like a hash.
    #
    def [](key)
      fields[key]
    end

    private

    # every parse_* method here should return { key: value, start: 0, length: 0 }
    def parse_raw(code, line, line_number)

      fields = (SIMPLE_FIELD_MAP[code] || [])
      if !fields.empty?
        starts = ([0] + Array(0...line.length).select { |i| line[i] == "," }.map(&:next))[0...fields.count]
        split = line.split(',', fields.count) # .map(&:strip)
        lengths = split.map(&:length)
        stripped_split = split.map(&:strip)
        hash_stuff = fields.zip(stripped_split, starts, lengths).map do |field, str, start, len|
          next [field, str, "#{field}_start".to_sym, start, "#{field}_length".to_sym, len] if field.is_a?(Symbol)

          key, block = field
          [key, block.to_proc.call(str), "#{key}_start".to_sym, start, "#{key}_length".to_sym, len]
        end
        Hash[*hash_stuff.flatten]
      elsif respond_to?("parse_#{code}_fields".to_sym, true)
        send("parse_#{code}_fields".to_sym, line, line_number)
      else
        raise ParseError.new('Unknown record code.')
      end
    end

    # Special cases need special implementations.
    #
    # The rules here are pulled from the specification at this URL:
    # http://www.bai.org/Libraries/Site-General-Downloads/Cash_Management_2005.sflb.ashx
    #
    def parse_transaction_detail_fields(record, line_number)
      # split out the constant bits
      starts = ([0] + Array(0...record.length-1).select { |i| record[i] == "," && record[i+1] != "," }.map(&:next))[0...5]
      split = record.split(',', 5)
      lengths = split.map(&:length)
      record_code, type_code, amount, funds_type, rest = split.map(&:strip)
      record_code_start, type_start, amount_start, funds_type_start, rest_start = starts
      record_code_len, type_len, amount_len, funds_type_len, rest_len = lengths

      common = {
        record_code: record_code,
        record_code_start: record_code_start,
        record_code_len: record_code_len,
        line_number: ,

        type: ParseTypeCode[type_code],
        type_start: type_start,
        type_len: type_len,

        amount:      amount.to_i,
        amount_start: amount_start,
        amount_length: amount_len,

        funds_type:  funds_type,
        funds_type_start: funds_type_start,
        funds_type_len: funds_type_len,
      }

      # handle funds_type logic
      funds_info, rest = *parse_funds_type(funds_type, rest, rest_start)
      with_funds_availability = common.merge(funds_info)

      # split the rest of the constant fields
      bank_ref, customer_ref, text = rest.split(',', 3).map(&:strip)

      with_funds_availability.merge(
        bank_reference:     bank_ref,
        customer_reference: customer_ref,
        text:               CleanContinuedText[text],
      )
    end

    def parse_account_identifier_fields(record)
      # split out the constant bits
      # record_code, customer, currency_code, rest = record.split(',', 4).map(&:strip)

      starts = ([0] + Array(0...record.length).select { |i| record[i] == "," }.map(&:next))[0...4]
      split = record.split(',', 4)
      lengths = split.map(&:length)
      record_code, customer, currency_code, rest = split.map(&:strip)
      record_code_start, customer_start, currency_code_start, rest_start = starts
      record_code_len, customer_len, currency_code_len, rest_len = lengths

      common = {
        record_code: record_code,
        record_code_start: record_code_start,
        record_code_length: record_code_len,

        customer: customer,
        customer_start: customer_start,
        customer_length: customer_len,

        currency_code: currency_code,
        currency_code_start: currency_code_start,
        currency_code_length: currency_code_len,

        summaries: []
      }

      # sadly, imperative style seems cleaner. would prefer it functional.
      until rest.nil? || rest.empty?

        # TODO
        type_code, amount, items_count, funds_type, rest \
          = rest.split(',', 5).map(&:strip)

        amount_details = {
          type: ParseTypeCode[type_code],
          amount: amount.to_i,
          items_count: items_count,
          funds_type: funds_type
        }

        # handle funds_type logic
        funds_info, rest = *parse_funds_type(funds_type, rest, rest_start)
        with_funds_availability = amount_details.merge(funds_info)

        common[:summaries] << with_funds_availability
      end

      common
    end

    # Takes a `fund_type` field, and the rest, and return a hashed of
    # interpreted values, and the new rest.
    #
    #   funds_type, rest = ...
    #   funds_info, rest = *parse_funds_type(funds_type, rest)
    #
    def parse_funds_type(funds_type, rest, rest_start)
      info = \
        case funds_type
        when 'S'
          # now, next_day, later, rest = rest.split(',', 4).map(&:strip)
          starts = ([0] + Array(0...rest.length).select { |i| rest[i] == "," }.map(&:next))[0...4]
          split = record.split(',', 4)
          lengths = split.map(&:length)
          now, next_day, later, rest = split.map(&:strip)
          now_start, next_day_start, later_start, rest_start = starts
          now_len, next_day_len, later_len, rest_len = lengths
          {
            availability: [
              {day: 0,    amount: now},
              {day: 1,    amount: now},
              {day: '>1', amount: now},
            ],
            availability_start: rest_start + now_start,
            availability_length: rest.length - rest_len
          }
        when 'V'
          # value_date, value_hour, rest = rest.split(',', 3).map(&:strip)
          starts = ([0] + Array(0...line.length).select { |i| rest[i] == "," }.map(&:next))[0...3]
          split = record.split(',', 3)
          lengths = split.map(&:length)
          value_date, _, _, rest = split.map(&:strip)
          value_date_start, = starts
          value_date_len, value_hour_len, rest_len = lengths
          value_hour = '2400' if value_hour == '9999'
          {
            value_dated: {date: value_date, hour: value_hour},
            value_date_start: rest_start + value_date_start,
            value_date_length: rest.length - rest_len
          }
        when 'D' # TODOO
          field_count, rest = rest.split(',', 2).map(&:strip)
          availability = field_count.to_i.times.map do
            days, amount, rest = rest.split(',', 3).map(&:strip)
            {days: days.to_i, amount: amount}
          end
          {availability: availability}
        else
          {}
        end
      [info, rest]
    end

  end
end
