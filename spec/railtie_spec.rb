describe RedisMemo::Railtie do
  class TestApplication < Rails::Application; end

  TestApplication.configure do
    config.eager_load = false
  end

  it 'inserts middleware' do
    Rails.application.initialize!
    expect(Rails.application.middleware.include?(RedisMemo::Middleware)).to eq(true)
  end
end
