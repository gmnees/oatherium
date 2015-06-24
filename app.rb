require "redis"
require "sinatra"
require "digest/sha1"
require "json"
require "date"
require 'sequel'
require 'thread'
require 'logger'

class PointAuction
  POSSES = ["Alan Kay", "Tim Berners-Lee", "Fred Brooks", "Donald Knuth", "Ada Lovelace", "Grace Hopper", "James Golick", "Weirich", "Adele Goldberg", "Dennis Ritchie", "Ezra Zygmuntowicz", "Yukihiro Matsumoto"]
  def self.redis
    @@redis
  end

  def self.redis=(redis)
    @@redis = redis
  end

  def self.current_auction
    if auction_data = redis.get("current_point_auction")
      new(JSON.parse(auction_data))
    else
      new
    end
  end

  attr_reader :bids, :active, :points

  def initialize(auction_data = {})
    @bids = auction_data["bids"] || {}
    @active = auction_data.fetch("active", true)
    @points = auction_data["points"] || 20
  end

  def total(posse)
    bids.fetch(posse, []).map do |b|
      b["value"]
    end.reduce(0, :+)
  end

  def posse_bid_messages(posse)
    bids.fetch(posse, []).map do |coin|
      coin["message"]
    end
  end

  def all_digests
    bids.flat_map do |p, coins|
      coins.map { |c| c["digest"] }
    end
  end

  def coin_already_bid?(coin)
    all_digests.include?(coin["digest"] || coin[:digest])
  end

  def place_bid(posse, coin)
    # take in sequel coin hashes (sym keys)
    # add to bid roster string-keyed hash of digest and val
    unless coin_already_bid?(coin)
      bids[posse] ||= []
      bids[posse] << {"digest" => coin[:digest], "value" => coin[:value]}
    end
  end

  def to_json
    {"bids" => bids, "active" => active, "points" => points}.to_json
  end

  def save!
    self.class.redis.set("current_point_auction", to_json)
  end

  def leader
    bids.sort_by do |posse, bids|
      total(posse)
    end.last.first
  end

  def complete!
    if award_id = GitCoin.database[:posse_awards].insert(value: points, posse: leader, created_at: Time.now)
      bids[leader].each do |bid|
        GitCoin.database[:debits].insert(digest: bid["digest"], posse_award_id: award_id, created_at: Time.now)
      end
    end
    @active = false
    save!
  end

  # initialize with point value
  # store current live auction in...redis?
  # need a ui where users can see
  #   * current point value up for auction
  #   * list of coins bid grouped by posse assignment
  #     (bids should show digest, coin value, and total value bid toward a given value)
  #   * form to submit additional bid by entering coin message and posse you are bidding for
  #
  # Q: How to reload the current point auction each request?
  # A: Serialize somehow? Redis

  # Q: What happens when ending an auction?
  # A: Need to:
  #    * record point award to highest "beneficiary" posse
  #    * debit / record spent the coins that were bid toward that posse
  #    * record that point auction has ended somehow

end

class GitCoin < Sinatra::Base
  set :logging, true
  TARGET_KEY = "gitcoin:current_target"
  GITCOINS_SET_KEY = "gitcoins:by_owner"
  AUTH_TOKEN = ENV["GITCOIN_TOKEN"] || "token"

  get "/auction" do
    erb :auction, locals: {auction: PointAuction.current_auction}
  end

  get "/awards" do
    database[:posse_awards].all.to_json
  end

  post "/bid" do
    bid = params["bid"] || {}
    posse = bid["posse"]
    message = bid["message"]
    auction = PointAuction.current_auction
    unless posse && message
      return {error: "Must provide coin message and posse attribution"}.to_json
    end
    unless PointAuction::POSSES.include?(posse)
      return {error: "Sorry, #{posse} is not a valid posse"}.to_json
    end
    unless coin = database[:coins].where(message: message).first
      return {error: "Sorry, #{message} is not a valid coin message"}.to_json
    end
    if database[:debits].where(digest: coin[:digest]).any?
      return {error: "Sorry, #{message} has already been spent"}.to_json
    end
    if bid = auction.place_bid(posse, coin)
      auction.save!
      return {success: "true", message: "bid coin #{coin[:digest]} toward #{posse}"}.to_json
    else
      return {error: "Sorry, #{message} has already been bid on this auction"}.to_json
    end
  end

  get "/target" do
    current_target
  end

  get "/gitcoins" do
    erb :gitcoins, locals: {gitcoins: gitcoins}
  end

  post "/hash" do
    content_type :json
    if coin = new_target?(params[:message], params[:owner])
      {:success => true, :gitcoin_assigned => coin, :new_target => current_target}.to_json
    else
      {:success => false, :gitcoin_assigned => false, :new_target => current_target}.to_json
    end
  end

  get "/coinbase" do
    if request["GITCOIN_TOKEN"] == AUTH_TOKEN
      messages_by_owner.to_json
    else
      {status: :not_authorized, message: "auth token required"}.to_json
    end
  end

  def self.redis
    @@redis
  end

  def self.assign_coin_lock
    @@lock ||= Mutex.new
  end

  def assign_coin_lock
    self.class.assign_coin_lock
  end

  def self.db_url
    ENV["DATABASE_URL"] || 'postgres://@localhost/gitcoins'
  end

  def self.database
    @@database ||= Sequel.connect(db_url)
  end

  def database
    self.class.database
  end

  def redis
    self.class.redis
  end

  def self.initialize_redis
    unless defined?(@@redis)
      if ENV["REDISTOGO_URL"] #heroku
        uri = URI.parse(ENV["REDISTOGO_URL"])
        @@redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
      else
        @@redis = Redis.new
      end

      redis.set(TARGET_KEY, largest_sha) unless redis.get(TARGET_KEY)
    end
  end

  def new_target?(message, owner)
    assign_coin_lock.synchronize do
      digest = Digest::SHA1.hexdigest(message)
      if unique_coin?(message) && lower_coin?(digest)
        assign_gitcoin(owner: owner, digest: digest, message: message, parent: current_target)
        set_target(digest)
      else
        false
      end
    end
  end

  def lower_coin?(digest)
    digest.hex < current_target.hex
  end

  def unique_coin?(message)
    database[:coins].where(message: message).none?
  end

  def set_target(digest)
    if below_reset_threshold?(digest)
      LOGGER.info("Coin #{digest} was below threshold; resetting to #{self.class.largest_sha}.")
      redis.set(TARGET_KEY, self.class.largest_sha)
    else
      redis.set(TARGET_KEY, digest)
    end
  end

  def below_reset_threshold?(digest)
    digest.hex < ("0000000" + "F" * 33).hex
  end

  def assign_gitcoin(options)
    options = options.merge(created_at: Time.now, value: value(options[:parent]))
    coin = GitCoin.database[:coins].insert(options)
    LOGGER.info("Assigned coin: #{options}.")
  end

  def zeros_count(digest)
    #number of leading 0's in digest
    digest[/\A0+/].to_s.length
  end

  def value(digest)
    case zeros_count(digest)
    when (0..4)
      1
    when (5..6)
      15
    else
      50
    end
  end

  def current_target
    redis.get(TARGET_KEY)
  end

  def gitcoins
    database[:coins].reverse_order(:created_at).all
  end

  def self.reset!
    initialize_redis
    redis.set(TARGET_KEY, largest_sha)
    LOGGER.info("reset the coins!")
  end

  def self.largest_sha
    "F" * 40
  end

  def messages_by_owner
    database[:coins].all.map do |c|
      {value: c[:value], message: c[:message], owner: c[:owner]}
    end.group_by do |c|
      c[:owner]
    end
  end

  def owners
    database[:coins].select(:owner).all.uniq
  end

  configure do
    initialize_redis
    PointAuction.redis = redis
    LOGGER = Logger.new(STDOUT)
  end
end

