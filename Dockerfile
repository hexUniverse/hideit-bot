FROM ruby:2.3.8-jessie

WORKDIR /usr/src/bot
COPY Gemfile Gemfile.lock ./
RUN bundle

COPY . .
CMD ["ruby","src/long_polling.rb"]