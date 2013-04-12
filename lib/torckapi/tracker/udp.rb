require 'socket'
require 'timeout'
require 'securerandom'
require 'torckapi/tracker/base'

module Torckapi
  module Tracker

    # Implementation of http://www.bittorrent.org/beps/bep_0015.html
    class UDP < Base
      CONNECTION_TIMEOUT = 60

      # index = action (connect, announce, scrape, error)
      # [response class, minimum response length]
      RESPONSES = [
        [nil, 16],
        [Torckapi::Response::Announce, 20],
        [Torckapi::Response::Scrape, 8],
        [Torckapi::Response::Error, 8]
      ].freeze

      # (see Base#announce)
      def announce info_hash
        super info_hash
        perform_request 1, announce_request_data(info_hash), info_hash
      end

      # (see Base#scrape)
      def scrape info_hashes=[]
        super info_hashes
        perform_request 2, scrape_request_data(info_hashes), info_hashes
      end

      private

      def perform_request action, data, *args
        connect
        response = communicate action, data

        raise CommunicationFailedError if response.nil?
        action = response[0][0..3].unpack('L>')[0]
        raise CommunicationFailedError if RESPONSES[action][1] > response[0].length

        begin
          RESPONSES[action][0].from_udp(*args, response[0][8..-1])
        rescue Torckapi::Response::ArgumentError => e
          $stderr.puts "Error: #{e.inspect}"
          $stderr.puts "Response: #{response.inspect}"
          raise CommunicationFailedError
        end
      end

      def announce_request_data info_hash
        [[info_hash].pack('H*'), SecureRandom.random_bytes(20), [0, 0, 0, 0, 0, 0, -1, 0].pack('Q>3L>4S>')].join
      end

      def scrape_request_data info_hashes
        info_hashes.map { |i| [i].pack('H*') }.join
      end

      def connect
        return if @connection_id && @communicated_at.to_i >= Time.now.to_i - CONNECTION_TIMEOUT

        @connection_id = [0x41727101980].pack('Q>')
        response = communicate 0 # connect
        raise ConnectionFailedError if response.nil? or 16 > response[0].length
        @connection_id = response[0][8..15]
      end

      def communicate action, data=nil
        @socket ||= UDPSocket.new

        transaction_id = SecureRandom.random_bytes(4)
        packet = [@connection_id, [action].pack('L>'), transaction_id, data].join

        tries = 0
        response = nil

        begin
          Timeout::timeout(@options[:timeout], CommunicationTimeoutError) do
            @socket.send(packet, 0, @url.host, @url.port)
            response = @socket.recvfrom(65536)
            raise TransactionIdMismatchError if transaction_id != response[0][4..7]
            @communicated_at = Time.now
          end
        rescue CommunicationTimeoutError
          retry if (tries += 1) <= @options[:tries]
          raise CommunicationFailedError
        end

        response
      end
    end
  end
end
