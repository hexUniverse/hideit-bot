require 'telegram/bot'
require 'telegram/bot/botan'
require 'mongo'
require_relative 'config'

module Hideit_bot

    class HideItBot

        def self.start()
            Mongo::Logger.logger.level = ::Logger::FATAL

            @@database_cleaner = Thread.new do
                # clean unused data
                mongoc = Mongo::Client.new("mongodb://mongodb:27017/hideitbot")
                counter = 0 # Only run every 30 seconds but sleep one second at a time
                loop do
                    sleep 1
                    counter = (counter + 1) % 30
                    if counter == 29
                        mongoc[:messages].delete_many(:used => false, :created_date => {:$lte => (Time.now - 30).utc})
                    end
                end
            end
        end

        def initialize()
            @bot = Telegram::Bot::Client.new(BotConfig::Telegram_token)
            @messages = Mongo::Client.new("mongodb://mongodb:27017/hideitbot", :pool_size => 5, :timeout => 5)[:messages]

            if BotConfig.has_botan_token
                @bot.enable_botan!(BotConfig::Botan_token)
            end
        end

        def listen(&block)
            @bot.listen &block
        end

        def process_update(message)
            case message
                when Telegram::Bot::Types::InlineQuery
                    id = handle_inline_query(message)
                    @bot.track('inline_query', message.from.id, {message_length: message.query.length, db_id: id})

                when Telegram::Bot::Types::CallbackQuery
                    res = message.data
                    begin
                        res = @messages.find("_id" => BSON::ObjectId(message.data)).to_a[0][:text]
                    rescue
                        res = "Message not found in database. Sorry!"
                    end
                    @bot.api.answer_callback_query(
                        callback_query_id: message.id,
                        text: res,
                        show_alert: true)
                    @bot.track('callback_query', message.from.id, {db_id: message.data})

                when Telegram::Bot::Types::ChosenInlineResult
                    message_type, message_id = message.result_id.split(':')
                    @messages.find("_id" => BSON::ObjectId(message_id))
                            .update_one(:$set => {used: true})
                    @bot.track('chosen_inline', message.from.id, {db_id: message_id, chosen_type: message_type})


                when Telegram::Bot::Types::Message
                    if message.text == "/start toolong"
                        @bot.api.send_message(chat_id: message.chat.id, text: "Unfortunately, due to telegram's api restrictions we cannot offer this functionality with messages over 200 characters. We'll try to find more options and contact telegram. Sorry for the inconvenience.")
                        @bot.track('message', message.from.id, message_type: 'toolong')
                    else
                        @bot.api.send_message(chat_id: message.chat.id, text: "Hello, #{message.from.first_name}!\nThis bot should be used inline.\nType @hideItBot to start")
                        @bot.api.send_message(chat_id: message.chat.id, text: "You can use it to send a spoiler in a group conversation.")
                        @bot.track('message', message.from.id, message_type: 'hello')
                    end

            end
        end

        def set_webhook(url)
            @bot.api.set_webhook(url: url)
        end

        private

        def message_to_blocks(message)
            return  message.gsub(/[^\s]/i, "\u2588")
        end

        def handle_inline_query(message)

            default_params = {}
            id = nil

            if message.query == ""
                results = []
                default_params = {
                    switch_pm_text: 'How to use this bot',
                    switch_pm_parameter: 'howto'
                }
            elsif message.query.length > 200
                results = []
                default_params = {
                    switch_pm_text: 'Sorry, this message is too long, split it to send.',
                    switch_pm_parameter: 'toolong'
                }
            else
                id = @messages.insert_one({user: message.from.id, text: message.query, used: false, created_date: Time.now.utc}).inserted_id.to_s
                results = [
                  ['1:'+id, 'Send covered text', message_to_blocks(message.query), message_to_blocks(message.query)],
                  ['2:'+id, 'Send generic message', '[[Hidden Message]]','[[Hidden Message]]']
                ].map do |arr|
                    Telegram::Bot::Types::InlineQueryResultArticle.new(
                        id: arr[0],
                        title: arr[1],
                        description: arr[2],
                        input_message_content: Telegram::Bot::Types::InputTextMessageContent.new(message_text: arr[3]),
                        reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
                            inline_keyboard: [
                                Telegram::Bot::Types::InlineKeyboardButton.new(
                                    text: 'Read',
                                    callback_data: id
                                )
                            ]
                        ),
                    )
                end
            end

            @bot.api.answer_inline_query({
                inline_query_id: message.id,
                results: results,
                cache_time: 0,
                is_personal: true
            }.merge!(default_params))
            return id
        end
    end
    
end