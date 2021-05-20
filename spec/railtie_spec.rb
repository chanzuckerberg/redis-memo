describe RedisMemo::Railtie do
  before(:each) do
    stub_const(
      'TestApplication',
      Class.new(Rails::Application),
    )
    TestApplication.configure do
      config.eager_load = false
    end
  end

  it 'inserts middleware' do
    Rails.application.initialize!
    expect(Rails.application.middleware.include?(RedisMemo::Middleware)).to eq(true)
  end
end
