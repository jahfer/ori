# Ori

Ori is a concurrency library for Ruby that provides a robust set of primitives for building concurrent applications. The name comes from the Japanese word 折り "ori" meaning "fold", reflecting how concurrent operations interleave.

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
  - [`Ori::Scope`](#oriscope)
    - [Timeouts and Cancellation](#timeouts-and-cancellation)
    - [Debugging](#debugging)
  - [Concurrency Utilities](#concurrency-utilities)
    - [`Ori::Promise`](#oripromise)
    - [`Ori::Channel`](#orichannel)
    - [`Ori::Mutex`](#orimutex)
    - [`Ori::Semaphore`](#orisemaphore)
- [Releases](#releases)
- [License](#license)

## Installation

```ruby
gem "ori"
```

Then execute:

```sh
bundle install
```

## Usage

### Ori::Scope

The core of Ori is the `Ori::Scope`, which provides a controlled environment for running fibers and managing their lifecycle.

```ruby
Ori::Scope.boundary do |scope|
  # Your concurrent code here
  scope.fork do
    # This runs in a new fiber
    sleep 1
    puts "Hello from fiber!"
  end
  # Multiple fibers can run concurrently
  scope.fork do
    sleep 0.5
    puts "Another fiber here!"
  end
end # Waits for all fibers to complete
```

<details>
<summary>See trace visualization</summary>

![Trace visualization](./docs/images/example_boundary.png)
</details>

#### Timeouts and Cancellation

You can also use `Ori::Scope.boundary` with timeouts to automatically cancel or raise after a specified duration. When using `cancel_after`, the scope will be cancelled but the boundary call will return normally. With `raise_after`, a `Ori::Scope::CancellationError` will be raised after the specified duration. Both options will properly clean up any running fibers.

Nested cancellation scopes are fully supported - a parent scope's deadline will be inherited by child scopes, and cancelling a parent scope will cancel all child scopes:

```ruby
Ori::Scope.boundary(raise_after: 5) do |scope|
  # This inner scope inherits the 5 second deadline
  scope.fork do
    # Will raise `Ori::Scope::CancellationError` after 5 seconds
    sleep(10)
  end

  # This inner scope has a shorter deadline
  Ori::Scope.boundary(cancel_after: 2) do |inner_scope|
    inner_scope.fork do
      # Will be cancelled after 2 seconds
      sleep(10)
    end
  end
end
```

<details>
<summary>See trace visualization</summary>

![Trace visualization](./docs/images/example_boundary_cancellation.png)
</details>

### Debugging

To help understand your program, Ori comes with several utilities to help you visualize the execution of your program.

#### `Ori::Scope#print_ascii_trace`

`Ori::Scope#print_ascii_trace` will print the trace to stdout in plaintext. While useful as a quick overview, it's not interactive and the level of detail is limited. 

```ruby
closed_scope = Ori::Scope.boundary { ... }
closed_scope.print_ascii_trace
```


```
Fiber Execution Timeline (0.001s)
==============================================================================================
Main       |▶.........↻.........................↻..................↻........................▒|
Fiber 1    |█▶═.╎------▶▒                                                                    |
Fiber 2    |   █▶═══~╎--▶~╎-----------------▶══~╎▶~╎------------▶══▒                         |
Fiber 3    |        █▶╎--▶╎----------------------▶╎----------------▶═~╎-----------------▶══▒ |
==============================================================================================
Legend: (█ Start) (▒ Finish) (═ Running) (~ IO-Wait) (. Sleeping) (╎ Yield) (✗ Error)
```

#### `Ori::Scope#write_html_trace(directory)`

`Ori::Scope#write_html_trace` will generate an `index.html` file in the specified directory containing a fully interactive timeline of the scope's execution.

```ruby
closed_scope = Ori::Scope.boundary { ... }
closed_scope.write_html_trace(File.join(__dir_, "out"))
```

![Trace visualization](./docs/images/example_trace.png)

### Concurrency Utilities

Ori comes with several utilities to help you build concurrent applications. Keep in mind that these utilities are not thread-safe and should only be used in a concurrent context. The particular usefulness of these utilities are primarily how they interact with the scheduler, yielding control back to other fibers when blocked.

#### `Ori::Promise`

Promises represent values that may not be immediately available. They're perfect for handling asynchronous operations.

```ruby
Ori::Scope.boundary do |scope|
  promise = Ori::Promise.new
  scope.fork do
    sleep 1
    promise.resolve("Hello from the future!")
  end
  # Wait for the promise to be fulfilled
  result = promise.await
  puts result # => "Hello from the future!"
end
```

<details>
<summary>See trace visualization</summary>

![Trace visualization](./docs/images/example_promise.png)
</details>

#### `Ori::Channel`

Channels provide a way to communicate between fibers by passing values between them:

```ruby
Ori::Scope.boundary do |scope|
  channel = Ori::Channel.new(5)
  # Producer
  scope.fork do
    5.times { |i| channel << i }
  end

  # Consumer
  scope.fork do
    5.times do
      puts "Received: #{channel.take}"
    end
  end
end
```

<details>
<summary>See trace visualization</summary>

![Trace visualization](./docs/images/example_channel.png)
</details>

Channels can be bounded to limit the number of items they can hold. When the channel is full, `put`/`<<` will block until there is room:

```ruby
channel = Ori::Channel.new(2)
scope.fork do
  5.times { |i| channel << i } # Will block after the first two puts
end
```

If a channel has a capacity of `0`, it becomes a simple synchronous queue:

```ruby
channel = Ori::Channel.new(0)
channel << 1 # Will block until `take` is called
```

#### `Ori::Mutex`

When you need to enforce a critical section with strict ordering, use a mutex:

```ruby
Ori::Scope.boundary do |scope|
  mutex = Ori::Mutex.new
  counter = 0
  5.times do
    scope.fork do
      mutex.synchronize do
        current = counter
        sleep 0.1 # Simulate work
        counter = current + 1
      end
    end
  end
end
```

<details>
<summary>See trace visualization</summary>

![Trace visualization](./docs/images/example_mutex.png)
</details>

#### `Ori::Semaphore`

Semaphors are a generalized form of mutexes that can be used to control access to _n_ limited resources:

```ruby
Ori::Scope.boundary do |scope|
  # Allow up to 3 concurrent operations
  semaphore = Ori::Semaphore.new(3)
  10.times do |i|
    scope.fork do
      semaphore.synchronize do
        puts "Processing #{i}"
        sleep 1 # Simulate work
      end
    end
  end
end
```

<details>
<summary>See trace visualization</summary>

![Trace visualization](./docs/images/example_semaphore.png)
</details>

## Releases

This gem is published to [Cloudsmith](https://cloudsmith.io/~shopify/repos/gems/packages).

The procedure to publish a new release version is as follows:

* Update `lib/ori/version.rb`
* Run bundle install to bump the version of the gem in `Gemfile.lock`
* Open a pull request, review, and merge
* Review commits since the last release to identify user-facing changes that should be included in the release notes
* [Create a release on GitHub](https://github.com/Shopify/ori/releases/new) with a version number that matches `lib/ori/version.rb`
* [Deploy via Shipit](https://shipit.shopify.io/shopify/ori/cloudsmith)

## License

The gem is available as open source under the terms of the MIT License.
