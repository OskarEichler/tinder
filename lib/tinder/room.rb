# encoding: UTF-8
require 'time'

module Tinder
  # A campfire room
  class Room
    attr_reader :id, :name

    def initialize(connection, attributes = {})
      @connection = connection
      @id = attributes['id']
      @name = attributes['name']
      @loaded = false
    end

    # Join the room
    # POST /room/#{id}/join.xml
    # For whatever reason, #join() and #leave() are still xml endpoints
    # whereas elsewhere in this API we're assuming json :\
    def join
      post 'join', 'xml'
    end

    # Leave a room
    # POST /room/#{id}/leave.xml
    def leave
      post 'leave', 'xml'
      stop_listening
    end

    # Get the url for guest access
    def guest_url
      "#{@connection.uri}/#{guest_invite_code}" if guest_access_enabled?
    end

    def guest_access_enabled?
      load
      @open_to_guests ? true : false
    end

    # The invite code use for guest
    def guest_invite_code
      load
      @active_token_value
    end

    # Change the name of the room
    def name=(name)
      update :name => name
    end
    alias_method :rename, :name=

    # Change the topic
    def topic=(topic)
      update :topic => topic
    end

    def update(attrs)
      connection.put("/room/#{@id}.json", {:room => attrs})
    end

    # Get the current topic
    def topic
      reload!
      @topic
    end

    # Lock the room to prevent new users from entering and to disable logging
    def lock
      post 'lock'
    end

    # Unlock the room
    def unlock
      post 'unlock'
    end

    # Post a new message to the chat room
    def speak(message, options = {})
      send_message(message)
    end

    def paste(message)
      send_message(message, 'PasteMessage')
    end

    def play(sound)
      send_message(sound, 'SoundMessage')
    end

    def tweet(url)
      send_message(url, 'TweetMessage')
    end

    # Get the list of users currently chatting for this room
    def users
      @users ||= current_users
    end

    def current_users
      reload!
      @current_users
    end

    # return the user with the given id; if it isn't in our room cache,
    # do a request to get it
    def user(id)
      if id
        cached_user = users.detect {|u| u[:id] == id }
        user = cached_user || fetch_user(id)
        self.users << user
        user
      end
    end

    # Perform a request for the user with the given ID
    def fetch_user(id)
      user_data = connection.get("/users/#{id}.json")
      user = user_data && user_data[:user]
      user[:created_at] = Time.parse(user[:created_at])
      user
    end

    # Modifies a hash representation of a Campfire message.  Expands +:user_id+
    # to a full hash at +:user+, generates Timestamp from +:created_at+.
    #
    # Full returned hash:
    # * +:body+: the body of the message
    # * +:user+: Campfire user, which is itself a hash, of:
    #   * +:id+: User id
    #   * +:name+: User name
    #   * +:email_address+: Email address
    #   * +:admin+: Boolean admin flag
    #   * +:created_at+: User creation timestamp
    #   * +:type+: User type (e.g. Member)
    # * +:id+: Campfire message id
    # * +:type+: Campfire message type
    # * +:room_id+: Campfire room id
    # * +:created_at+: Message creation timestamp
    def parse_message(message)
      message[:user] = user(message.delete(:user_id))
      message[:created_at] = Time.parse(message[:created_at])
      message
    end

    # Listen for new messages in the room, parsing them with #parse_message
    # and then yielding them to the provided block as they arrive.
    #
    #   room.listen do |m|
    #     room.speak "Go away!" if m[:body] =~ /Java/i
    #   end
    def listen(options = {})
      raise ArgumentError, "no block provided" unless block_given?

      Tinder.logger.info "Joining #{@name}…"
      join # you have to be in the room to listen

      require 'json'
      require 'hashie'
      require 'multi_json'
      require 'twitter/json_stream'

      auth = connection.basic_auth_settings
      options = {
        :host => "streaming.#{Connection::HOST}",
        :path => room_url_for('live'),
        :auth => "#{auth[:username]}:#{auth[:password]}",
        :timeout => 6,
        :ssl => connection.options[:ssl]
      }.merge(options)

      Tinder.logger.info "Starting EventMachine server…"
      EventMachine::run do
        @stream = Twitter::JSONStream.connect(options)
        Tinder.logger.info "Listening to #{@name}…"
        @stream.each_item do |message|
          message = Hashie::Mash.new(MultiJson.decode(message))
          message = parse_message(message)
          yield(message)
        end

        @stream.on_error do |message|
          raise ListenFailed.new("got an error! #{message.inspect}!")
        end

        @stream.on_max_reconnects do |timeout, retries|
          raise ListenFailed.new("Tried #{retries} times to connect. Got disconnected from #{@name}!")
        end

        # if we really get disconnected
        raise ListenFailed.new("got disconnected from #{@name}!") if !EventMachine.reactor_running?
      end
    end

    def listening?
      @stream != nil
    end

    def stop_listening
      return unless listening?

      Tinder.logger.info "Stopped listening to #{@name}…"
      @stream.stop
      @stream = nil
    end

    # Get the transcript for the given date (Returns a hash in the same format as #listen)
    #
    #   room.transcript(Time.now)
    #   #=> [{:message=>"foobar!",
    #         :user_id=>"99999",
    #         :person=>"Brandon",
    #         :id=>"18659245",
    #         :timestamp=>=>Tue May 05 07:15:00 -0700 2009}]
    #
    # The timestamp slot will typically have a granularity of five minutes.
    #
    def transcript(transcript_date = Date.today)
      url = "/room/#{@id}/transcript/#{transcript_date.strftime('%Y/%m/%d')}.json"
      connection.get(url)['messages'].map do |message|
        parse_message(message)
      end
    end

    # Search transcripts for the given term (returns an array of messages parsed
    # via #parse_message, see #parse_message for format of returned message)
    #
    def search(term)
      encoded_term = Addressable::URI.encode(term)

      room_messages = connection.get("/search/#{encoded_term}.json")["messages"].select do |message|
        message[:room_id] == id
      end

      room_messages.map do |message|
        parse_message(message)
      end
    end

    def upload(file, content_type = nil, filename = nil)
      require 'mime/types'
      content_type ||= MIME::Types.type_for(filename || file)
      raw_post(:uploads, { :upload => Faraday::UploadIO.new(file, content_type, filename) })
    end

    # Get the list of latest files for this room
    def files(count = 5)
      get(:uploads)['uploads'].map { |u| u['full_url'] }
    end

    # Get a list of recent messages
    # Accepts a hash for options:
    # * +:limit+: Restrict the number of messages returned
    # * +:since_message_id+: Get messages created after the specified message id
    def recent(options = {})
      options = { :limit => 10, :since_message_id => nil }.merge(options)
      # Build url manually, faraday has to be 8.0 to do this
      url = "#{room_url_for(:recent)}?limit=#{options[:limit]}&since_message_id=#{options[:since_message_id]}"

      connection.get(url)['messages'].map do |msg|
        parse_message(msg)
      end
    end

  protected

    def load
      reload! unless @loaded
    end

    def reload!
      attributes = connection.get("/room/#{@id}.json")['room']

      @id = attributes['id']
      @name = attributes['name']
      @topic = attributes['topic']
      @full = attributes['full']
      @open_to_guests = attributes['open_to_guests']
      @active_token_value = attributes['active_token_value']
      @current_users = attributes['users'].map do |user|
        user[:created_at] = Time.parse(user[:created_at])
        user
      end

      @loaded = true
    end

    def send_message(message, type = 'TextMessage')
      post 'speak', {:message => {:body => message, :type => type}}
    end

    def get(action)
      connection.get(room_url_for(action))
    end

    def post(action, body = nil)
      connection.post(room_url_for(action), body)
    end

    def raw_post(action, body = nil)
      connection.raw_post(room_url_for(action), body)
    end

    def room_url_for(action, format="json")
      "/room/#{@id}/#{action}.#{format}"
    end

    def connection
      @connection
    end

  end
end
