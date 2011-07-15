module Duckweed
  class Token
    TOKEN_HASH_NAME = 'duckweed:auth_tokens'

    def self.authorize(token)
      if token.to_s.empty?
        raise ArgumentError, "Token must not be empty"
      end
      redis.hset(TOKEN_HASH_NAME, token, "rw")
      token
    end

    def self.authorized?(token)
      redis.hexists(TOKEN_HASH_NAME, token)
    end

    def self.deauthorize(token)
      redis.hdel(TOKEN_HASH_NAME, token)
    end

    def self.all
      redis.hgetall(TOKEN_HASH_NAME).keys
    end

    private
    def self.redis
      Duckweed.redis
    end

  end
end
