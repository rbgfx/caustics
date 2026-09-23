<h1 align="center">Caustics</h1>

<p align="center">A deterministic pure Ruby path tracer and teaching example.</p>

<p align="center">
  <a href="https://rubygems.org/gems/caustics"><img src="https://badge.fury.io/rb/caustics.svg" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/caustics"><img src="https://img.shields.io/gem/dt/caustics?label=downloads" alt="Downloads"></a>
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/ruby-%3E%3D3.1-CC342D?logo=ruby&amp;logoColor=white" alt="Ruby Version"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-750014.svg" alt="License"></a>
</p>

[Features](#features) · [Installation](#installation) · [Quick Start](#quick-start) · [Engines](#engines)

***

Caustics is a small ray tracer for experimenting with cameras, materials, textures, acceleration, and renderer backends. The Ruby engine is the reference implementation; optional RLSL and Metal engines cover a deliberately smaller shader subset.

## Features

- Rays, spheres, planes, triangles, quads, and a BVH accelerator.
- Lambertian, metal, dielectric, emission, checker, image, and Perlin textures.
- Depth of field, deterministic per-pixel sampling, and an accumulator.
- Process-parallel rendering where <code>fork</code> is available.
- Interactive preview with progressive sampling.
- Ruby, rlsl C, and Metal command-line engines.

## Installation

Add Caustics to your Gemfile:

~~~ruby
gem "caustics"
~~~

Then run:

~~~sh
bundle install
~~~

Or install the released gem:

~~~sh
gem install caustics
~~~

### Requirements

- Ruby 3.1 or newer.
- The Metal engine requires macOS with a Metal-capable device.

## Quick Start

Render the included scene:

~~~sh
caustics render scenes/weekend.rb --size 400x225 --spp 16 --workers 4 -o out.png
caustics preview scenes/weekend.rb --size 400x225 --spp 16 -o preview.png
~~~

Use the Ruby API directly:

~~~ruby
require "caustics"

scene = Caustics::Scene.build do
  sphere center: [0, 0, 0], radius: 0.5,
         material: lambertian([0.8, 0.2, 0.2])
end

Caustics.render(scene, width: 320, height: 180, spp: 16, workers: 4).write("out.png")
~~~

## Engines

~~~sh
caustics bench scenes/shader.rb --size 64x36 --spp 2 --engine ruby,rlsl_c
caustics render scenes/shader.rb --engine rlsl_c --size 400x225 --spp 2 --max-depth 2 -o out.png
caustics codegen scenes/shader.rb
~~~

The <code>:rlsl_c</code> and <code>:metal</code> engines currently support
constant-colored Lambertian spheres with deterministic sampling and bounce
limits. The Metal engine requires a Metal-capable macOS host.

## Development

~~~sh
bundle install
bundle exec rake verify
~~~

## Contributing

Bug reports and pull requests are welcome at [rbgfx/caustics](https://github.com/rbgfx/caustics).

## License

[MIT](LICENSE.txt)
