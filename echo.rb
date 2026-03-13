# echo.rb
require 'line-bot-api'

module EchoBot
  module_function

  def handle(events)
    client = Line::Bot::V2::MessagingApi::ApiClient.new(channel_access_token: ENV.fetch("ECHO_BOT_CHANNEL_TOKEN"))

    events.each do |event|
      if event.is_a?(Line::Bot::V2::Webhook::MessageEvent) && event.message.is_a?(Line::Bot::V2::Webhook::TextMessageContent)
        req = Line::Bot::V2::MessagingApi::ReplyMessageRequest.new(
          reply_token: event.reply_token,
          messages: [
              Line::Bot::V2::MessagingApi::TextMessage.new(text: "[ECHO] #{event.message.text}")
            ]
        )
        client.reply_message(reply_message_request: req)
      end
    end
  end
end
