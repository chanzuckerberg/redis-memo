describe RedisMemo::ThreadLocalVar do
  it 'prints a warning when re-defining a thread local var' do
    RedisMemo::ThreadLocalVar.define :rspec_test
    expect {
      RedisMemo::ThreadLocalVar.define :rspec_test
    }.to output(/warning/).to_stderr
  end
end
