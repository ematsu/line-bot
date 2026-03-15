# Line bot for Book reading memo

Yet another script for MyDNS.JP users to renew let's encrypt certificate with manual authenticator

## Installation
Step1:

```bash
$ cd /your/domain/directory/
$ wget 'https://github.com/ematsu/line-bot/archive/master.zip' -O line-bot-master.zip
$ unzip ./line-bot-master.zip
$ cd /your/domain/directory/line-bot-master/
```

Step2:

```bash
edit ".env".

    export ECHO_BOT_CHANNEL_SECRET="XXXXX"
    export ECHO_BOT_CHANNEL_TOKEN="XXXXX"
    export BOOK_BOT_CHANNEL_SECRET="XXXXX"
    export BOOK_BOT_CHANNEL_TOKEN="XXXXX"
    export GOOGLE_API_KEY="XXXXX"
    export RAKUTEN_APP_ID="XXXXX"
    export RAKUTEN_ACCESS_KEY="XXXXX"

```

## Usage

```bash

$ bundle exec ruby main.rb -o 127.0.0.1 -p 4567

```

## Development

Nothing special.

## Contributing

Nothing special.

## License

This script is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

