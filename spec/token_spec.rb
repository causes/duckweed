require 'spec_helper'

describe Duckweed::Token do
  context ".authorize(token)" do
    it "returns token" do
      described_class.authorize('foo').should == 'foo'
    end

    it "makes .authorized?(token) true" do
      token = "salty-sea-dogs"

      described_class.authorized?(token).should be_false
      described_class.authorize(token)
      described_class.authorized?(token).should be_true
    end

    it "raises an error on nil" do
      lambda do
        described_class.authorize(nil)
      end.should raise_error(ArgumentError)
    end

    it "raises an error on empty string" do
      lambda do
        described_class.authorize("")
      end.should raise_error(ArgumentError)
    end
  end

  context ".deauthorize(token)" do
    it "makes .authorized?(token) false" do
      token = "scurvy-cur"
      described_class.authorize(token)
      described_class.authorized?(token).should be_true

      described_class.deauthorize(token)
      described_class.authorized?(token).should be_false
    end
  end
end 
