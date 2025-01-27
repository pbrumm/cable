require "uuid"

module Cable
  class Connection
    class UnathorizedConnectionException < Exception; end

    @@mock : Cable::Connection?

    property internal_identifier : String = "0"
    getter token : String?
    getter connection_identifier : String

    CHANNELS = {} of String => Hash(String, Cable::Channel)

    getter socket
    getter id : String
    getter request : HTTP::Request

    def identifier
      ""
    end

    macro identified_by(name)
      @{{name.id}} : String = ""

      def {{name.id}}=(value : String)
        @{{name.id}} = value
      end

      def {{name.id}}
        @{{name.id}}
      end

      private def internal_identifier
        @{{name.id}}
      end
    end

    macro owned_by(type_definition)
      @{{type_definition.var}} : {{type_definition.type}}?

      def {{type_definition.var}}=(value : {{type_definition.type}})
        @{{type_definition.var}} = value
      end

      def {{type_definition.var}}
        @{{type_definition.var}}
      end
    end

    def self.use_mock(mock, &block)
      @@mock = mock

      yield

      @@mock = nil
    end

    def self.build(request : HTTP::Request, socket : HTTP::WebSocket)
      if mock = @@mock
        return mock
      else
        self.new(request, socket)
      end
    end

    def initialize(@request : HTTP::Request, @socket : HTTP::WebSocket)
      @token = @request.query_params.fetch(Cable.settings.token, nil)
      @id = UUID.random.to_s
      @connection_identifier = ""

      begin
        connect
        @connection_identifier = "#{internal_identifier}-#{@id}"
      rescue e : UnathorizedConnectionException
        socket.close(HTTP::WebSocket::CloseCode::NormalClosure, "Farewell")
        Cable::Logger.info("An unauthorized connection attempt was rejected")
      end
    end

    def connect
      raise Exception.new("Implement the `connect` method")
    end

    def close
      return true unless Connection::CHANNELS.has_key?(connection_identifier)
      Connection::CHANNELS[connection_identifier].each do |identifier, channel|
        channel.close
        Connection::CHANNELS[connection_identifier].delete(identifier)
      end
      socket.close
    end

    def reject_unauthorized_connection
      raise UnathorizedConnectionException.new
    end

    def receive(message)
      payload = Cable::Payload.new(message)

      return subscribe(payload) if payload.command == "subscribe"
      return unsubscribe(payload) if payload.command == "unsubscribe"
      return message(payload) if payload.command == "message"
    end

    def subscribe(payload : Cable::Payload)
      channel = Cable::Channel::CHANNELS[payload.channel].new(
        connection: self,
        identifier: payload.identifier,
        params: payload.channel_params
      )
      Connection::CHANNELS[connection_identifier] ||= {} of String => Cable::Channel
      Connection::CHANNELS[connection_identifier][payload.identifier] = channel
      channel.subscribed

      return reject(channel) if channel.subscription_rejected?

      if stream_identifier = channel.stream_identifier
        Cable.server.subscribe_channel(channel: channel, identifier: stream_identifier)
        Cable::Logger.info "#{channel.class.to_s} is streaming from #{stream_identifier}"
      end

      Cable::Logger.info "#{payload.channel} is transmitting the subscription confirmation"
      socket.send({type: "confirm_subscription", identifier: payload.identifier}.to_json)
    end

    def unsubscribe(payload : Cable::Payload)
      if channel = Connection::CHANNELS[connection_identifier].delete(payload.identifier)
        channel.close
        Cable::Logger.info "#{payload.channel} is transmitting the unsubscribe confirmation"
        socket.send({type: "confirm_unsubscription", identifier: payload.identifier}.to_json)
      end
    end

    def reject(channel : Cable::Channel)
      Connection::CHANNELS[connection_identifier].delete(channel.identifier)
      Cable::Logger.info "#{channel.class.to_s} is transmitting the subscription rejection"
      socket.send({type: "reject_subscription", identifier: channel.identifier}.to_json)
    end

    def message(payload : Cable::Payload)
      if Connection::CHANNELS[connection_identifier].has_key?(payload.identifier)
        channel = Connection::CHANNELS[connection_identifier][payload.identifier]
        if payload.action?
          Cable::Logger.info "#{channel.class}#perform(\"#{payload.action}\", #{payload.data})"
          channel.perform(payload.action, payload.data)
        else
          begin
            Cable::Logger.info "#{channel.class}#receive(#{payload.data})"
            channel.receive(payload.data)
          rescue e : TypeCastError
          end
        end
      end
    end

    def self.broadcast_to(channel : String, message : String)
      Cable.server.publish("#{channel}", message)
    end
  end
end
