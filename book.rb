require 'sinatra'
require 'line-bot-api'
require 'net/http'
require 'json'
require 'uri'
require 'date'
require 'base64'

# --- Constants ---
ISBN_PATTERN = /(97[89]\d{10}|\d{10})/
VISION_API_URL = "https://vision.googleapis.com/v1/images:annotate"
BOOKS_API_URL  = "https://www.googleapis.com/books/v1/volumes"
RAKUTEN_API_URL = "https://openapi.rakuten.co.jp/services/api/BooksTotal/Search/20170404"

# --- Module definition ---
module BookBot
  module_function

  def extract_isbn(image_binary)
    payload = {
      requests: [{
        image: { content: Base64.strict_encode64(image_binary) },
        features: [{ type: "TEXT_DETECTION" }]
      }]
    }.to_json

    res = post_request("#{VISION_API_URL}?key=#{ENV['GOOGLE_API_KEY']}", payload)
    text = res.dig("responses", 0, "fullTextAnnotation", "text") || ""
    text.gsub(/[-－\s]/, '').match(ISBN_PATTERN)&.[](1)
  end

  def fetch_from_openbd(isbn)
    return nil if isbn.nil?
    uri = URI.parse("https://api.openbd.jp/v1/get?isbn=#{isbn}")
    response = Net::HTTP.get(uri)
    data = JSON.parse(response).first # OpenBD returns array

    return nil if data.nil?

    # Get info. from summary level
    {
      publisher: data.dig("summary", "publisher"),
      pub_date:  data.dig("summary", "pubdate") # "YYYYMMDD" format
    }
  rescue => e
    puts "OpenBD Error: #{e.message}"
    nil
  end

  def fetch_info(input_text)
    clean_input = input_text.gsub(/[-－\s]/, '')
    is_isbn = clean_input.match?(/\A#{ISBN_PATTERN}\z/)

    # 1. Search by ISBN or Title
    query = is_isbn ? "isbn:#{clean_input}" : "intitle:#{URI.encode_www_form_component(input_text.strip)}"
    res = get_request("#{BOOKS_API_URL}?q=#{query}&maxResults=1&key=#{ENV['GOOGLE_API_KEY']}")
    item = res.dig("items", 0, "volumeInfo") || {}

    # Identify ISBN
    target_isbn = is_isbn ? clean_input : extract_isbn_from_google(item)

    # 2. Get publisher and salesdate from OpenBD
    if target_isbn && item["publisher"].to_s.empty?
      openbd_data = fetch_from_openbd(target_isbn)
      if openbd_data
        # Supplement if Google does NOT return data
        item["publisher"] ||= openbd_data[:publisher]
        item["publishedDate"] ||= openbd_data[:pub_date]
      end
    end

    # Check whether need supplement or not
    needs_supplement = item["publisher"].to_s.empty? ||
                       item["publishedDate"].to_s.length < 10

    # 3. Supplement by Rakuten API
    if target_isbn && needs_supplement
      rakuten_data = fetch_from_rakuten(target_isbn)
      if rakuten_data
        # Overwrite when Rakuten returns "effective" data
        unless rakuten_data[:publisher].to_s.empty?
          item["publisher"] = rakuten_data[:publisher]
        end

        unless rakuten_data[:pub_date].to_s.empty?
          item["publishedDate"] = rakuten_data[:pub_date]
        end

        item["title"] ||= rakuten_data[:title]
        item["authors"] ||= [rakuten_data[:authors]]
      end
    end

    {
      title:     item["title"] || "不明",
      authors:   item["authors"]&.join(", ") || "不明",
      pub_date:  format_date(item["publishedDate"]),
      publisher: item["publisher"] || "不明"
    }
  end

  def fetch_from_rakuten(isbn)
    return nil if isbn.nil?
    # Remove "-" from ISBN code
    pure_isbn = isbn.gsub(/\D/, '')
    uri = URI.parse("#{RAKUTEN_API_URL}?format=json&isbnjan=#{pure_isbn}&applicationId=#{ENV['RAKUTEN_APP_ID']}&accessKey=#{ENV['RAKUTEN_ACCESS_KEY']}")

    begin
      response = Net::HTTP.get(uri)
      data = JSON.parse(response).dig("Items", 0, "Item")
      return nil unless data

      {
        title:     data["title"],
        authors:   data["author"],
        pub_date:  data["salesDate"], # Like "2024年03月"
        publisher: data["publisherName"]
      }
    rescue => e
      puts "Rakuten API Error: #{e.message}"
      nil
    end
  end

  def post_request(url, body)
    uri = URI.parse(url)
    res = Net::HTTP.post(uri, body, { 'Content-Type' => 'application/json' })
    JSON.parse(res.body)
  end

  def get_request(url)
    JSON.parse(Net::HTTP.get(URI.parse(url)))
  end

  def format_date(date_str)
    return "不明" if date_str.nil? || date_str.empty?

    # 1. Completely cleaning
    clean_date = date_str.to_s
                         .tr('－ー', '-')           # 全角ハイフン・長音を半角に
                         .gsub(/[頃日]/, '')        # 「頃」「日」を消す
                         .gsub(/[年月]/, '-')       # 「年」「月」をハイフンに
                         .gsub(/-+$/, '')           # 末尾のハイフンを消す
                         .strip

    # 2. Adjust OpenBD format to include "-"
    if clean_date.match?(/\A\d{8}\z/)
      clean_date = clean_date.gsub(/(\d{4})(\d{2})(\d{2})/, '\1-\2-\3')
    end

    # 3. add "-01" if day info. is missing
    if clean_date.match?(/\A\d{4}-\d{2}\z/)
      clean_date += "-01"
    end

    begin
      # Format to YYYY/MM/DD
      Date.parse(clean_date).strftime("%Y/%m/%d")
    rescue ArgumentError, TypeError
      # If error, just return the original date_str
      clean_date
    end
  end

  def build_template(book)
    <<~TEXT.chomp
      ★基本情報
      ・タイトル：#{book[:title]}
      ・作者：#{book[:authors]}
      ・発行日：#{book[:pub_date]}
      ・出版社名：#{book[:publisher]}
      ・読んだ日付：#{Date.today.strftime("%Y/%m/%d")}
      ★所感など
      ・手にとったきっかけ：
      ・引っかかった言葉：
      ・感想：
    TEXT
  end

  def handle(events)
    client = Line::Bot::V2::MessagingApi::ApiClient.new(channel_access_token: ENV.fetch("BOOK_BOT_CHANNEL_TOKEN"))
    blob_client = Line::Bot::V2::MessagingApi::ApiBlobClient.new(channel_access_token: ENV.fetch("BOOK_BOT_CHANNEL_TOKEN"))

    events.each do |event|
      next unless event.is_a?(Line::Bot::V2::Webhook::MessageEvent)

      reply_text = case event.message
      when Line::Bot::V2::Webhook::TextMessageContent
        book = BookBot.fetch_info(event.message.text)
        book ? build_template(book) : "「#{event.message.text}」に一致する本が見つかりませんでした。"

      when Line::Bot::V2::Webhook::ImageMessageContent
        image_blob = blob_client.get_message_content(message_id: event.message.id)
        isbn = BookBot.extract_isbn(image_blob)

        if isbn
          book = BookBot.fetch_info(isbn)
          book ? build_template(book) : "ISBN(#{isbn})は見つかりましたが、Google Booksに詳細がありませんでした。"
        else
          "画像からISBN（978で始まるコード）を読み取れませんでした。"
        end
      end

      if reply_text
        req = Line::Bot::V2::MessagingApi::ReplyMessageRequest.new(
          reply_token: event.reply_token,
          messages: [
              Line::Bot::V2::MessagingApi::TextMessage.new(text: reply_text)
            ]
        )
        client.reply_message(reply_message_request: req)
      end
    end
  end
end
