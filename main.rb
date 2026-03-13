# main.rb
require 'sinatra'
require 'line-bot-api'

require_relative 'book'
require_relative 'echo'

set :environment, :production

# Common Logic
helpers do
  def parse_events(secret)
    signature = request.env['HTTP_X_LINE_SIGNATURE']
    parser = Line::Bot::V2::WebhookParser.new(channel_secret: secret)
    begin
      parser.parse(body: request.body.read, signature: signature)
    rescue Line::Bot::V2::WebhookParser::InvalidSignatureError
      halt 400, "Invalid signature"
    end
  end
end

# Book Bot
post '/bot/book' do
  events = parse_events(ENV.fetch("BOOK_BOT_CHANNEL_SECRET"))
  BookBot.handle(events)
  "OK"
end

# Echo Bot
post '/bot/echo' do
  events = parse_events(ENV.fetch("ECHO_BOT_CHANNEL_SECRET"))
  EchoBot.handle(events)
  "OK"
end
