require 'spec_helper'

if ENV["TEST_REAL_HTTP"]
  # Create a config.yml file containing the following:
  # :account: <account name>
  # :secret: <secret>
  # then run the specs with TEST_REAL_HTTP=true
  describe "CloudQuery account" do
    before(:each) do
      @config = YAML.load(File.read('config.yml'))
      @client = Cloudquery::Client.new(@config)
    end

    it "gets your account information from the server" do
      response_hash = @client.get_account.last
      response_hash.should have_key("result")
      response_hash["result"].should have_key("secret")
      response_hash["result"]["secret"].should == @config[:secret]

      response_hash["result"].should have_key("name")
      response_hash["result"]["name"].should == @config[:account]

      response_hash["result"].should have_key("preferences")
    end
  end
end

describe Cloudquery::Request do
  before(:each) do
    @valid_options = {
      :scheme => 'http',
      :host => 'example.com',
      :path => '/v0/',
    }
  end
  
  def request(additional_options={})
    return @request if defined?(@request)
    @request = Cloudquery::Request.new(@valid_options.merge(additional_options))
  end

  it "instantiates with valid options" do
    lambda { request }.should_not raise_error
  end


  describe "append_signature" do
    it "should append the signature as the x_sig parameter at the end of the query string" do
      url = 'http://example.com/path?query=string'
      signed_url = request.send(:append_signature, url, 'secret')
      signed_url.should match(/^#{url.sub(/\?/, '\\?')}/)
      signed_url.should match(/x_sig=[-\w]+(?:%3D)*$/)
    end
  end

  describe "signature_params" do
    describe "without an account present" do
      it "should return an empty hash" do
        request.send(:signature_params).should == {}
      end
    end

    describe "with an account present" do
      before(:each) do
        @params = request(:account => 'account').send(:signature_params)
      end
    
      it "should return a hash with the x_name parameter with the account name" do
        @params.should have_key('x_name')
        @params['x_name'].should == 'account'
      end
    
      it "should return a hash with the x_time parameter with the current milliseconds since epoch" do
        @params.should have_key('x_time')
        @params['x_time'].should be_close(Time.now.to_i_with_milliseconds, 100)
      end
    
      it "should return a hash with the x_nonce parameter of the format \d+.\d+" do
        @params.should have_key('x_nonce')
        @params['x_nonce'].should match(/^\d+.\d+$/)
      end
    
      it "should return a hash with the x_method parameter with the signing method name" do
        @params.should have_key('x_method')
        @params['x_method'].should == Cloudquery::SIGNING_METHOD
      end
    end
  end
  
  describe "query_str" do
    it "builds a query string from the request params" do
      request(:params => {'these' => 'params'})
      request.send(:query_str).should == 'these=params'
    end
    
    it "url-encodes params with non alphanumeric characters (outside [ a-zA-Z0-9-._])" do
      request(:params => {'weird' => 'values=here'})
      request.send(:query_str).should == 'weird=values%3Dhere'
    end
    
    it "returns an empty string when no params are present" do
      request(:params => {}).send(:query_str) == ""
    end
  end
  
  describe "base_uri" do
    it "returns an http url when the scheme is http" do
      request(:scheme => 'http').send(:base_uri).should be_an_instance_of(URI::HTTP)
    end
    it "returns an https url when the scheme is https" do
      request(:scheme => 'https').send(:base_uri).should be_an_instance_of(URI::HTTPS)
    end
  end
end

describe Cloudquery::Crypto::Random do
  describe "nonce generation" do
    it "generates a nonce with a random number, a dot, and the current time" do
      nonce = Cloudquery::Crypto::Random.number
      nonce.should match(/^\d+.\d+$/)
      random_digits, time = nonce.split('.')
      time.to_i.should be_close(Time.now.to_i, 1)
      random_digits.should match(/^\d+$/)
    end
  end
end

describe Cloudquery::Crypto::Sha1 do
  describe "sign" do
    it "takes an abritrary number of tokens to encrypt" do
      lambda { Cloudquery::Crypto::Sha1.sign }.should_not raise_error
      lambda { Cloudquery::Crypto::Sha1.sign('a') }.should_not raise_error
      lambda { Cloudquery::Crypto::Sha1.sign('a', 'b', 'c') }.should_not raise_error
    end
    
    it "produces a base64 encoded SHA1 digest of the tokens without whitespace at the end" do
      b64 = Base64.encode64(Digest::SHA1.digest('a')).chomp
      Cloudquery::Crypto::Sha1.sign('a').should == b64
    end
  end
end

