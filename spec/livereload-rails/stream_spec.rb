require "socket"

describe Livereload::Stream do
  let!(:server)  { TCPServer.new("localhost", 0) }
  let!(:local)  { TCPSocket.new("localhost", server.addr(true)[1]) }
  let!(:remote) { server.accept }

  it "can stream from/to an IO" do
    thread = Thread.new(local) do |io|
      received = []

      stream = Livereload::Stream.new(io) do |data|
        received << data.dup
        stream.write(data.upcase)
      end
      stream.write("Hi this is stream!")
      stream.loop

      received
    end

    sent = []
    sent << remote.read(18)
    remote.write("Hello stream!")
    sent << remote.read(13)
    remote.write("What up?!")
    sent << remote.read(9)
    remote.close

    received = thread.value
    expect(received).to eq(["Hello stream!", "What up?!"])
    expect(sent).to eq(["Hi this is stream!", "HELLO STREAM!", "WHAT UP?!"])
  end

  context "exits gracefully" do
    let(:received) { "" }
    let(:append) { proc { |data| received << data.dup } }
    let(:fail) { proc { raise "This should not be reached" } }

    def threaded_wait(stream)
      thread = Thread.new do
        stream.write "OK"
        stream.loop
      end

      remote.read(2)
      Thread.pass until thread.status == "sleep"
      thread
    end

    context "when IO is closed remotely" do
      specify "before looping" do
        remote.close
        stream = Livereload::Stream.new(local, &fail)
        stream.loop
      end

      specify "during reading" do
        remote.write "This is cool"

        io = FakeIO.new(local, read_buffer: 8)
        io.on(:read_nonblock) { remote.close unless remote.closed? }

        stream = Livereload::Stream.new(io, &append)
        stream.loop

        expect(received).to eq "This is cool"
      end

      specify "during writing" do
        data = ""
        io = FakeIO.new(local, write_buffer: 8)
        io.on(:write_nonblock) { data << remote.readpartial(100) }
        io.on(:write_nonblock) { remote.close unless remote.closed? }

        stream = Livereload::Stream.new(io, &fail)
        stream.write "This is cool."
        stream.loop

        expect(data).to eq("This is ")
      end

      specify "after looping" do
        stream = Livereload::Stream.new(local, &append)
        thread = threaded_wait(stream)

        remote.close
        thread.value
      end
    end

    context "when IO is closed locally" do
      specify "before looping" do
        local.close
        stream = Livereload::Stream.new(local, &fail)
        stream.loop
      end

      specify "during reading" do
        remote.write "This is cool"

        io = FakeIO.new(local, read_buffer: 8)
        io.on(:read_nonblock) { local.close unless local.closed? }

        stream = Livereload::Stream.new(io, &append)
        stream.loop

        expect(received).to eq "This is "
      end

      specify "during writing" do
        data = ""
        io = FakeIO.new(local, write_buffer: 8)
        io.on(:write_nonblock) { data << remote.readpartial(100) }
        io.on(:write_nonblock) { local.close unless local.closed? }

        stream = Livereload::Stream.new(io, &fail)
        stream.write "This is cool."
        stream.loop

        expect(data).to eq("This is ")
      end

      specify "after looping" do
        stream = Livereload::Stream.new(local, &append)
        thread = threaded_wait(stream)

        local.close
        thread.value
      end
    end
  end

  context "exits catastrophically and deregisters from the selector" do
    let(:error) { StandardError.new("CRASH!") }
    let(:selector) { NIO::Selector.new }

    specify "if reading crashes" do
      remote.write "This is cool."

      stream = Livereload::Stream.new(local, selector: selector) { raise error }

      expect { stream.loop }.to raise_error(error)
      expect(selector.registered?(local)).to eq(false)
    end

    specify "if writing crashes" do
      expect(local).to receive(:write_nonblock).and_raise(error)

      stream = Livereload::Stream.new(local, selector: selector) { |data| raise "data: #{data} received in error" }
      stream.write "Outgoing data."

      expect { stream.loop }.to raise_error(error)
      expect(selector.registered?(local)).to eq(false)
    end
  end
end
