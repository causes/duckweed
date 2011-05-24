require "spec_helper"

describe Duckweed::App do
  let(:event) { 'test-event-47781' }
  let(:app) { described_class }
  let(:default_params) { { :auth_token => Duckweed::AUTH_TOKENS.first } }

  describe "POST /track/:event" do
    before { freeze_time }

    it_should_behave_like 'pages with auth' do
      def do_request
        post "/track/#{event}", {}
      end
    end

    context 'with a new event' do
      it 'succeeds' do
        post "/track/#{event}", default_params
        last_response.should be_successful
      end

      it 'responds with "OK"' do
        post "/track/#{event}", default_params
        last_response.body.should =~ /ok/i
      end

      it "increments a key with minute-granularity in Redis" do
        expect { post "/track/#{event}", default_params }.to change {
          Duckweed.redis.get("duckweed:#{event}:minutes:#{@now.to_i / 60}")
        }.from(nil).to('1')
      end

      it "increments a key with hour-granularity in Redis" do
        expect { post "/track/#{event}", default_params }.to change {
          Duckweed.redis.get("duckweed:#{event}:hours:#{@now.to_i / 3600}")
        }.from(nil).to('1')
      end

      it "increments a key with day-granularity in Redis" do
        expect { post "/track/#{event}", default_params }.to change {
          Duckweed.redis.get("duckweed:#{event}:days:#{@now.to_i / 86400}")
        }.from(nil).to('1')
      end

      context 'with a quantity param' do
        let(:params) { default_params.merge(:quantity => 15) }

        it 'succeeds' do
          post "/track/#{event}", params
          last_response.should be_successful
        end

        it 'responds with "OK"' do
          post "/track/#{event}", params
          last_response.body.should =~ /ok/i
        end

        it "increments a key with minute-granularity in Redis" do
          expect { post "/track/#{event}", params }.to change {
            Duckweed.redis.get("duckweed:#{event}:minutes:#{@now.to_i / 60}")
          }.from(nil).to('15')
        end

        it "increments a key with hour-granularity in Redis" do
          expect { post "/track/#{event}", params }.to change {
            Duckweed.redis.get("duckweed:#{event}:hours:#{@now.to_i / 3600}")
          }.from(nil).to('15')
        end

        it "increments a key with day-granularity in Redis" do
          expect { post "/track/#{event}", params }.to change {
            Duckweed.redis.get("duckweed:#{event}:days:#{@now.to_i / 86400}")
          }.from(nil).to('15')
        end
      end
    end

    context 'with a previously-seen event' do
      before do
        post "/track/#{event}", default_params
      end

      it 'succeeds' do
        post "/track/#{event}", default_params
        last_response.should be_successful
      end

      it 'responds with "OK"' do
        post "/track/#{event}", default_params
        last_response.body.should =~ /ok/i
      end

      it "increments a key with minute-granularity in Redis" do
        expect { post "/track/#{event}", default_params }.to change {
          Duckweed.redis.get("duckweed:#{event}:minutes:#{@now.to_i / 60}").to_i
        }.by(1)
      end

      it "increments a key with hour-granularity in Redis" do
        expect { post "/track/#{event}", default_params }.to change {
          Duckweed.redis.get("duckweed:#{event}:hours:#{@now.to_i / 3600}").to_i
        }.by(1)
      end

      it "increments a key with day-granularity in Redis" do
        expect { post "/track/#{event}", default_params }.to change {
          Duckweed.redis.get("duckweed:#{event}:days:#{@now.to_i / 86400}").to_i
        }.by(1)
      end

      context 'with a quantity param' do
        let(:params) { default_params.merge(:quantity => 15) }

        it 'succeeds' do
          post "/track/#{event}", params
          last_response.should be_successful
        end

        it 'responds with "OK"' do
          post "/track/#{event}", params
          last_response.body.should =~ /ok/i
        end

        it "increments a key with minute-granularity in Redis" do
          expect { post "/track/#{event}", params }.to change {
            Duckweed.redis.get("duckweed:#{event}:minutes:#{@now.to_i / 60}").to_i
          }.by(15)
        end

        it "increments a key with hour-granularity in Redis" do
          expect { post "/track/#{event}", params }.to change {
            Duckweed.redis.get("duckweed:#{event}:hours:#{@now.to_i / 3600}").to_i
          }.by(15)
        end

        it "increments a key with day-granularity in Redis" do
          expect { post "/track/#{event}", params }.to change {
            Duckweed.redis.get("duckweed:#{event}:days:#{@now.to_i / 86400}").to_i
          }.by(15)
        end
      end
    end

    context 'with an explicit timestamp param' do
      before do
        # simulate a big delay in a Beanstalk queue
        @timestamp = @now.to_i - 6000
      end

      it 'uses the timestamp rather than Time.now' do
        Duckweed.redis.should_receive(:incr).
          with("duckweed:#{event}:minutes:#{@timestamp / 60}")
        Duckweed.redis.should_receive(:incr).
          with("duckweed:#{event}:hours:#{@timestamp / 3600}")
        Duckweed.redis.should_receive(:incr).
          with("duckweed:#{event}:days:#{@timestamp / 86400}")
        post "/track/#{event}", default_params.merge(:timestamp => @timestamp)
      end

      it "does not make fine-grained records for long-ago events" do
        long_ago = Time.now.to_i - (86400*30)  # 30 days
        post "/track/#{event}", default_params.merge(:timestamp => long_ago)

        # NB: the redis mock gets cleared before every example
        Duckweed.redis.keys('*').should ==
          ["duckweed:#{event}:days:#{long_ago / 86400}"]
      end
    end

    it 'expires minute-granularity data after a day' do
      Duckweed.redis.stub!(:expire)
      Duckweed.redis.should_receive(:expire).
        with("duckweed:#{event}:minutes:#{@now.to_i / 60}", 86400)
      post "/track/#{event}", default_params
    end

    it 'expires hour-granularity data after a week' do
      Duckweed.redis.stub!(:expire)
      Duckweed.redis.should_receive(:expire).
        with("duckweed:#{event}:hours:#{@now.to_i / 3600}", 86400 * 7)
      post "/track/#{event}", default_params
    end

    it 'expires day-granularity data after a year' do
      Duckweed.redis.stub!(:expire)
      Duckweed.redis.should_receive(:expire).
        with("duckweed:#{event}:days:#{@now.to_i / 86400}", 86400 * 365)
      post "/track/#{event}", default_params
    end
  end
end