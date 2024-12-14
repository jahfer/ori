# Ori

Ori is a library for Ruby that provides a robust set of primitives for building concurrent applications. The name comes from the Japanese word 折り "ori" meaning "fold", reflecting how concurrent operations interleave.

Ori provides a set of primitives that allow you to build concurrent applications—that is, applications that interleave execution within a single thread—without blocking the entire Ruby interpreter for each task.

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
  - [Defining Boundaries](#defining-boundaries)
    - [Matching](#matching)
    - [Timeouts and Cancellation](#timeouts-and-cancellation)
    - [Enumerables](#enumerables)
    - [Debugging](#debugging)
  - [Concurrency Utilities](#concurrency-utilities)
    - [`Ori::Promise`](#oripromise)
    - [`Ori::Channel`](#orichannel)
    - [`Ori::Mutex`](#orimutex)
    - [`Ori::Semaphore`](#orisemaphore)
    - [`Ori::Timeout`](#oritimeout)
- [Releases](#releases)
- [License](#license)

## Installation

```ruby
gem "shopify-ori", "~> 0.2"
```

Then execute:

```sh
bundle install
```

In your Ruby code, you can then require the library:

```ruby
require "ori"
```

## Usage

Ori aims to make concurrency in Ruby simple, intuitive, and easy to manage. There are only two decisions you need to make when using Ori: 

1. What code must complete _before_ other code starts?
2. What code can run at the same time as other code?

### Defining Boundaries

At the core of Ori is the concurrency boundary. Ori guarantees everything inside of a boundary will complete before any code after the boundary starts. Boundaries can be freely nested, allowing you to define critical sections inside of other critical sections.

To create a new concurrency boundary, call `Ori.sync` with your block of code. Once inside the boundary, you can use `Ori::Scope#fork` to define and run concurrent work. Code written inside of the boundary but outside of `Ori::Scope#fork` will run synchronously from the perspective of the boundary. `Ori::Scope#fork` will return an `Ori::Task` object, which you can use to wait for the fiber to complete, or retrieve its result.

```ruby
Ori.sync do |scope|
  # This runs in a new fiber
  scope.fork do
    sleep 1
    puts "Hello from fiber!"
  end

  # This doesn't wait for the first fiber to complete
  scope.fork do
    sleep 0.5
    puts "Another fiber here!"
  end
end

# Ori.sync blocks until all fibers complete
puts "Success!"
```

**Output:**

```
Another fiber here!
Hello from fiber!
Success!
```

<details>
<summary>See trace visualization</summary>

![Trace visualization](./docs/images/example_boundary.png)
</details>

#### Matching

Ori has powerful support for matching against concurrent resources. If you have a set of blocking resources, you can use `Ori.select` in combination with Ruby's `case … in` pattern-matching to wait on the first available resource.

`Ori.select` will block until the first resource becomes available, returning that value and cancel waiting for the others. Matching against Ori's utility classes is particularly efficient because Ori can check internally if the blocking resources are available before attempting the heavier task of resuming the code.

See [Concurrency Utilities](#concurrency-utilities) for more details on these classes.

```ruby
promise = Ori::Promise.new
mutex = Ori::Mutex.new
channel = Ori::Channel.new(1)
timeout = Ori::Timeout.new(0.1) # stop after 100ms if no resource completes

case Ori.select([promise, mutex, channel, timeout])
in Ori::Promise(value) then puts "Promise: #{value}"
in Ori::Mutex          then puts "Mutex acquired!"
in Ori::Channel(value) then puts "Channel: #{value}"
in Ori::Timeout        then puts "Timeout!"
end
```

This matching syntax can also be leveraged to race multiple tasks against each other, in very compact form:

```ruby
Ori.sync do |scope|
  # Spawn 3 tasks
  tasks = scope.fork_each(3.times).map { do_work }

  # Wait for the first task to complete
  Ori.select(tasks) => Ori::Task(value)
  puts "First result: #{value}"

  # Stop processing any further tasks
  scope.shutdown!
end
```

If you have multiple of the same resource, you can perform an explicit match using Ruby's pattern matching syntax:

```ruby
promise_a = Ori::Promise.new
promise_b = Ori::Promise.new

case Ori.select([promise_a, promise_b])
in Ori::Promise(value) => p if p == promise_a
  puts "Promise A: #{value}"
in Ori::Promise(value) => p if p == promise_b
  puts "Promise B: #{value}"
end
```

#### Timeouts and Cancellation

You can also use `Ori.sync` with timeouts to automatically cancel or raise after a specified duration. 

When using `cancel_after: seconds`, the scope will be cancelled but the boundary will close with raising an error. With `raise_after: seconds`, a `Ori::Scope::CancellationError` will be raised from the boundary call site after the specified duration. Both options will properly clean up any internally-spawned fibers and nested scopes.

A parent scope's deadline is inherited by child scopes, and cancelling a parent scope will cancel all child scopes:

```ruby
Ori.sync(raise_after: 5) do |scope|
  # This inner scope inherits the 5 second deadline
  scope.fork do
    # Will raise `Ori::CancellationError` after 5 seconds
    sleep(10)
  end

  # This inner scope has a shorter deadline
  Ori.sync(cancel_after: 2) do |child_scope|
    child_scope.fork do
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

### Enumerables

As a convenience, `Ori::Scope` provides an `#fork_each` method that will spawn a new fiber for each item in an enumerable. This can be useful for performing concurrent operations on a collection.

The following code contains six seconds of `sleep` time, but will take only ~1 second to execute due to the interleaving of the fibers:

```ruby
Ori.sync do |scope|
  # Spawns a new fiber for each item in the array
  scope.fork_each([1, 2, 3]) do |item|
    puts "Processing #{item}"
    sleep(1)
  end

  # Any Enumerable can be used
  scope.fork_each(3.times) do |i|
    puts "Processing #{i}"
    sleep(1)
  end
end
```

### Debugging

To help understand your program, Ori comes with several utilities to help you visualize the execution of your program, as well as being supported by the broader Ruby ecosystem.

#### Vernier 

The HEAD of [jhawthorn/vernier](https://github.com/jhawthorn/vernier) supports tracking the spawning and yielding of fibers, to help analyze your concurrent program over time.

#### Plain-Text Visualization

`Ori::Scope#print_ascii_trace` will print the trace to stdout in plaintext. While useful as a quick overview, it's not interactive and the level of detail is limited. 

```ruby
closed_scope = Ori.sync { ... }
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

#### HTML Visualization

`Ori::Scope#write_html_trace(dir)` will generate an `index.html` file in the specified directory containing a fully interactive timeline of the scope's execution. 

![Trace visualization](./docs/images/example_trace.png)

##### Tags

`#write_html_trace` also supports use of `Ori::Scope#tag` to add custom labels to the trace.

```ruby
closed_scope = Ori.sync do |scope|
  scope.fork do
    scope.tag("Going to sleep")
    sleep(0.0001)
    scope.tag("Woke up")
  end

  scope.fork do
    scope.tag("Not sure what to do")
    Fiber.yield
    scope.tag("Finished yielding")
  end

  scope.tag("Finished queueing work")
end

closed_scope.write_html_trace(File.join(__dir_, "out"))
```

![Trace visualization](./docs/images/example_trace_tag.png)

### Concurrency Utilities

Ori comes with several utilities to help you build concurrent applications. Keep in mind that these utilities are not thread-safe and should only be used in a concurrent context. The particular usefulness of these utilities are primarily how they interact with the scheduler, yielding control back to other fibers when blocked.

#### `Ori::Promise`

Promises represent values that may not be immediately available:

```ruby
Ori.sync do |scope|
  promise = Ori::Promise.new
  scope.fork do
    sleep(1)
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

Channels provide a way to communicate between fibers by passing values between them. Channels can buffer up to a specified number of items. When the channel is full, `put`/`<<` will block until there is room:

```ruby
Ori.sync do |scope|
  channel = Ori::Channel.new(2)
  # Producer
  scope.fork do
    # Will block after the first two puts
    5.times { |i| channel << i }
  end

  # Consumer
  scope.fork do
    5.times { puts "Received: #{channel.take}" }
  end
end
```

<details>
<summary>See trace visualization</summary>

![Trace visualization](./docs/images/example_channel.png)
</details>

If a channel has a capacity of `0`, it becomes a simple synchronous queue:

```ruby
channel = Ori::Channel.new(0)
channel << 1 # Will block until `take` is called
```

#### `Ori::Mutex`

When you need to enforce a critical section with strict ordering, use a mutex:

```ruby
result = []
Ori.sync do |scope|
  mutex = Ori::Mutex.new
  counter = 0

  scope.fork do
    mutex.sync do
      current = counter
      result << [:A, :read, current]
      Fiber.yield # Simulate work
      counter = current + 1
      result << [:A, :write, counter]
    end
  end

  scope.fork do
    mutex.sync do
      current = counter
      result << [:B, :read, current]
      counter = current + 1
      result << [:B, :write, counter]
    end
  end
end

result.each { |r| puts r.inspect }
```

**Output:**

```
[:A, :read, 0]
[:A, :write, 1]
[:B, :read, 1]
[:B, :write, 2]
```

Without a mutex, the `counter` variable would be read and written in an interleaved manner, leading to race conditions where both fibers read `0`:

```
[:A, :read, 0]
[:B, :read, 0]
[:B, :write, 1]
[:A, :write, 1]
```

<details>
<summary>See trace visualization</summary>

![Trace visualization](./docs/images/example_mutex.png)
</details>

#### `Ori::Semaphore`

Semaphors are a generalized form of mutexes that can be used to control access to _n_ limited resources:

```ruby
Ori.sync do |scope|
  # Allow up to 3 concurrent operations
  semaphore = Ori::Semaphore.new(3)

  10.times do |i|
    scope.fork do
      semaphore.sync do
        puts "Processing #{i}"
        sleep(1) # Simulate work
      end
    end
  end
end
```

#### `Ori::Timeout`

A timeout is a special resource that will cancel after a specified duration. It's primary use case is as a resource in `Ori.select`.

```ruby
Ori.sync do |scope|
  promise = Ori::Promise.new
  timeout = Ori::Timeout.new(0.1) # stop after 100ms if the promise hasn't resolved

  scope.fork do
    sleep(0.2)
    promise.resolve("Hello from the future!")
  end

  case Ori.select([promise, timeout])
  in Ori::Promise(value) then puts "Promise: #{value}"
  in Ori::Timeout then puts "Timeout!"
  end
end
```

**Output:**

```
Timeout!
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
