require 'sinatra'
require 'line-bot-api'
require 'net/http'
require 'json'
require 'uri'
require 'date'
require 'base64'

# --- 設定・定数 ---
ISBN_PATTERN = /(97[89]\d{10}|\d{10})/
VISION_API_URL = "https://vision.googleapis.com/v1/images:annotate"
BOOKS_API_URL  = "https://www.googleapis.com/books/v1/volumes"

# --- 外部サービス連携ロジック ---
module BookBot
  module_function

  # Google Vision APIで画像からISBNを抽出
  def extract_isbn(image_binary)
    payload = {
      requests: [{
        image: { content: Base64.strict_encode64(image_binary) },
        features: [{ type: "TEXT_DETECTION" }]
      }]
    }.to_json

    res = post_request("#{VISION_API_URL}?key=#{ENV['BOOKS_API_KEY']}", payload)
    text = res.dig("responses", 0, "fullTextAnnotation", "text") || ""
    text.gsub(/[-－\s]/, '').match(ISBN_PATTERN)&.[](1)
  end

  # OpenBDから出版社名を取得する（ISBNが必要）
  def fetch_publisher_from_openbd(isbn)
    return nil if isbn.nil?
  
    uri = URI.parse("https://api.openbd.jp/v1/get?isbn=#{isbn}")
    begin
      response = Net::HTTP.get(uri)
      data = JSON.parse(response)
      # OpenBDは配列で返ってくる。データがあれば出版社名を返す
      data.dig(0, "summary", "publisher")
    rescue
      nil # エラー時はおとなしくnilを返す
    end
  end

  # Google Books APIから情報を取得
  def fetch_info(input_text)
    clean_input = input_text.gsub(/[-－\s]/, '')
    is_isbn = clean_input.match?(/\A#{ISBN_PATTERN}\z/)

    # 1. まずはISBN（またはタイトル）で検索
    query = is_isbn ? "isbn:#{clean_input}" : "intitle:#{URI.encode_www_form_component(input_text.strip)}"
    res = get_request("#{BOOKS_API_URL}?q=#{query}&maxResults=1&key=#{ENV['BOOKS_API_KEY']}")
    item = res.dig("items", 0, "volumeInfo")

    return nil unless item

    # --- 【ステップ2】Google Books内での再検索ロジック ---
    if item["publisher"].nil? || item["publisher"].empty?
      retry_query = "intitle:#{URI.encode_www_form_component(item['title'])}"
      retry_query += "+inauthor:#{URI.encode_www_form_component(item['authors'][0])}" if item["authors"]&.any?

      retry_res = get_request("#{BOOKS_API_URL}?q=#{retry_query}&maxResults=1&key=#{ENV['BOOKS_API_KEY']}")
      retry_item = retry_res.dig("items", 0, "volumeInfo")

      if retry_item && retry_item["publisher"]
        item["publisher"] = retry_item["publisher"]
        item["publishedDate"] ||= retry_item["publishedDate"]
      end
    end

    # --- 【追加ステップ3】それでもダメならOpenBDで補完 ---
    if item["publisher"].nil? || item["publisher"].empty?
      # OpenBDを叩くためにISBNを特定する
      # 入力がISBNならそれを使い、そうでなければGoogle Booksの結果からISBNを抜き出す
      target_isbn = if is_isbn
                      clean_input
                    else
                      # industryIdentifiersの中からISBN_13を優先して探す
                      item["industryIdentifiers"]&.find { |id| id["type"] == "ISBN_13" }&.[]("identifier") ||
                      item["industryIdentifiers"]&.find { |id| id["type"] == "ISBN_10" }&.[]("identifier")
                    end

      if target_isbn
        # 実装済みとされている関数を呼び出し
        openbd_publisher = fetch_publisher_from_openbd(target_isbn)
        if openbd_publisher && !openbd_publisher.empty?
          item["publisher"] = openbd_publisher
        end
      end
    end
    # ------------------------------------------------------------

    {
      title:     item["title"] || "不明",
      authors:   item["authors"]&.join(", ") || "不明",
      pub_date:  format_date(item["publishedDate"]),
      publisher: item["publisher"] || "不明"
    }
  end
 
  # 共通リクエスト処理
  def post_request(url, body)
    uri = URI.parse(url)
    res = Net::HTTP.post(uri, body, { 'Content-Type' => 'application/json' })
    JSON.parse(res.body)
  end

  def get_request(url)
    JSON.parse(Net::HTTP.get(URI.parse(url)))
  end

  # 日付整形
  def format_date(date_str)
    return "不明" if date_str.nil? || date_str.empty?
    # Ruby 3.4の柔軟な日付解析を活用
    Date.parse(date_str).strftime("%Y/%m/%d") rescue date_str.gsub('-', '/')
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
