# frozen_string_literal: true

require "tessel"

require_relative "caustics/version"

module Caustics
  class Error < StandardError; end
  class UnsupportedError < ArgumentError; end

  class Vec3
    attr_accessor :x, :y, :z
    def initialize(x = 0, y = 0, z = 0) = (@x, @y, @z = x.to_f, y.to_f, z.to_f)
    def +(other) = Vec3.new(x + other.x, y + other.y, z + other.z)
    def -(other) = Vec3.new(x - other.x, y - other.y, z - other.z)
    def -@ = Vec3.new(-x, -y, -z)
    def *(other) = other.is_a?(Vec3) ? Vec3.new(x * other.x, y * other.y, z * other.z) : Vec3.new(x * other, y * other, z * other)
    def /(other) = self * (1.0 / other)
    def dot(other) = x * other.x + y * other.y + z * other.z
    def cross(other) = Vec3.new(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
    def length = Math.sqrt(dot(self))
    def normalize = length.zero? ? self : self / length
    def near_zero? = [x, y, z].all? { |value| value.abs < 1e-8 }
    def to_a = [x, y, z]
    def self.random(rng, min: 0.0, max: 1.0) = new(rng.rand(min...max), rng.rand(min...max), rng.rand(min...max))
    def self.random_unit(rng)
      loop do
        value = new(rng.rand(-1.0...1.0), rng.rand(-1.0...1.0), rng.rand(-1.0...1.0))
        next if value.dot(value) >= 1 || value.near_zero?
        return value.normalize
      end
    end
    def reflect(normal) = self - normal * 2 * dot(normal)
    def refract(normal, ratio)
      cos_theta = [-self.dot(normal), 1.0].min
      perpendicular = (self + normal * cos_theta) * ratio
      parallel = normal * -Math.sqrt((1.0 - perpendicular.dot(perpendicular)).abs)
      perpendicular + parallel
    end
  end

  Ray = Struct.new(:origin, :direction) do
    def at(distance) = origin + direction * distance
  end
  Hit = Struct.new(:point, :normal, :t, :front_face, :material, keyword_init: true)

  class Aabb
    attr_reader :minimum, :maximum

    def initialize(minimum:, maximum:)
      @minimum, @maximum = minimum, maximum
    end

    def hit?(ray, minimum, maximum)
      3.times do |axis|
        origin = ray.origin.to_a[axis]
        direction = ray.direction.to_a[axis]
        lower = @minimum.to_a[axis]
        upper = @maximum.to_a[axis]
        if direction.abs < Float::EPSILON
          return false if origin < lower || origin > upper
          next
        end

        inverse = 1.0 / direction
        first = (lower - origin) * inverse
        last = (upper - origin) * inverse
        first, last = last, first if first > last
        minimum = first if first > minimum
        maximum = last if last < maximum
        return false if maximum < minimum
      end
      true
    end

    def self.around(left, right)
      new(
        minimum: Vec3.new(
          [left.minimum.x, right.minimum.x].min,
          [left.minimum.y, right.minimum.y].min,
          [left.minimum.z, right.minimum.z].min
        ),
        maximum: Vec3.new(
          [left.maximum.x, right.maximum.x].max,
          [left.maximum.y, right.maximum.y].max,
          [left.maximum.z, right.maximum.z].max
        )
      )
    end
  end

  class BvhNode
    attr_reader :box

    def initialize(objects)
      raise ArgumentError, "BVH needs at least one object" if objects.empty?

      if objects.length == 1
        @left = @right = objects.first
        @box = @left.bounding_box
        return
      end

      axis = longest_axis(objects)
      sorted = objects.sort_by { |object| object.bounding_box.minimum.to_a[axis] + object.bounding_box.maximum.to_a[axis] }
      midpoint = sorted.length / 2
      @left = sorted.take(midpoint)
      @right = sorted.drop(midpoint)
      @left = @left.length == 1 ? @left.first : BvhNode.new(@left)
      @right = @right.length == 1 ? @right.first : BvhNode.new(@right)
      @box = Aabb.around(@left.bounding_box, @right.bounding_box)
    end

    def hit(ray, minimum, maximum)
      return unless @box.hit?(ray, minimum, maximum)

      left_hit = @left.hit(ray, minimum, maximum)
      right_limit = left_hit ? left_hit.t : maximum
      right_hit = @right.equal?(@left) ? nil : @right.hit(ray, minimum, right_limit)
      right_hit || left_hit
    end

    def bounding_box = @box

    private

    def longest_axis(objects)
      bounds = objects.map(&:bounding_box).reduce { |left, right| Aabb.around(left, right) }
      lengths = bounds.maximum.to_a.zip(bounds.minimum.to_a).map { |max, min| max - min }
      lengths.each_with_index.max_by(&:first).last
    end
  end

  class Sphere
    attr_reader :center, :radius, :material
    def initialize(center:, radius:, material:)
      @center, @radius, @material = center, radius.to_f, material
      raise ArgumentError, "sphere radius must be positive and finite" unless @radius.finite? && @radius.positive?
    end

    def hit(ray, minimum, maximum)
      offset = ray.origin - @center
      half_b = offset.dot(ray.direction)
      discriminant = half_b * half_b - ray.direction.dot(ray.direction) * (offset.dot(offset) - @radius * @radius)
      return unless discriminant >= 0
      root = Math.sqrt(discriminant)
      root = (-half_b - root) / ray.direction.dot(ray.direction)
      root = (-half_b + root) / ray.direction.dot(ray.direction) unless root.between?(minimum, maximum)
      return unless root.between?(minimum, maximum)

      point = ray.at(root)
      outward = (point - @center) / @radius
      front_face = ray.direction.dot(outward).negative?
      Hit.new(point: point, normal: front_face ? outward : -outward, t: root, front_face: front_face, material: @material)
    end

    def bounding_box
      radius = Vec3.new(@radius, @radius, @radius)
      Aabb.new(minimum: @center - radius, maximum: @center + radius)
    end
  end

  class Plane
    attr_reader :point, :normal, :material

    def initialize(point:, normal:, material:)
      @point, @normal, @material = point, normal.normalize, material
      raise ArgumentError, "plane normal must not be zero" if @normal.near_zero?
    end

    def hit(ray, minimum, maximum)
      denominator = ray.direction.dot(@normal)
      return if denominator.abs < Float::EPSILON

      distance = (@point - ray.origin).dot(@normal) / denominator
      return unless distance.between?(minimum, maximum)

      front_face = ray.direction.dot(@normal).negative?
      Hit.new(point: ray.at(distance), normal: front_face ? @normal : -@normal, t: distance,
              front_face: front_face, material: @material)
    end
  end

  class Triangle
    attr_reader :a, :b, :c, :material

    def initialize(a:, b:, c:, material:)
      @a, @b, @c, @material = a, b, c, material
      raise ArgumentError, "triangle vertices must not be collinear" if edge1.cross(edge2).near_zero?
    end

    def hit(ray, minimum, maximum)
      h = ray.direction.cross(edge2)
      determinant = edge1.dot(h)
      return if determinant.abs < Float::EPSILON

      inverse = 1.0 / determinant
      s = ray.origin - @a
      u = inverse * s.dot(h)
      return unless u.between?(0.0, 1.0)

      q = s.cross(edge1)
      v = inverse * ray.direction.dot(q)
      return unless v >= 0.0 && u + v <= 1.0

      distance = inverse * edge2.dot(q)
      return unless distance.between?(minimum, maximum)

      outward = edge1.cross(edge2).normalize
      front_face = ray.direction.dot(outward).negative?
      Hit.new(point: ray.at(distance), normal: front_face ? outward : -outward, t: distance,
              front_face: front_face, material: @material)
    end

    def bounding_box
      points = [@a.to_a, @b.to_a, @c.to_a]
      minimum = 3.times.map { |axis| points.map { |point| point[axis] }.min }
      maximum = 3.times.map { |axis| points.map { |point| point[axis] }.max }
      Aabb.new(minimum: Vec3.new(*minimum), maximum: Vec3.new(*maximum))
    end

    private

    def edge1 = @b - @a
    def edge2 = @c - @a
  end

  class Quad
    attr_reader :material

    def initialize(a:, b:, c:, d:, material:)
      @material = material
      @triangles = [Triangle.new(a: a, b: b, c: c, material: material),
                    Triangle.new(a: a, b: c, c: d, material: material)]
    end

    def hit(ray, minimum, maximum)
      @triangles.filter_map { |triangle| triangle.hit(ray, minimum, maximum) }.min_by(&:t)
    end

    def bounding_box
      @triangles.map(&:bounding_box).reduce { |left, right| Aabb.around(left, right) }
    end
  end

  class Material
    def initialize(color: Vec3.new(1, 1, 1), fuzz: 0, index: 1.5, emission: Vec3.new(0, 0, 0), kind: :lambertian)
      @index = Float(index)
      raise ArgumentError, "refractive index must be positive and finite" unless @index.finite? && @index.positive?
      fuzz = Float(fuzz)
      raise ArgumentError, "material fuzz must be finite" unless fuzz.finite?
      @color, @fuzz, @emission, @kind = color, fuzz.clamp(0, 1), emission, kind
    end
    attr_reader :color, :emission, :index, :kind

    def scatter(ray, hit, rng)
      case @kind
      when :lambertian
        direction = hit.normal + Vec3.random_unit(rng)
        direction = hit.normal if direction.near_zero?
        [Ray.new(hit.point, direction), @color.respond_to?(:value) ? @color.value(hit.point) : @color]
      when :metal
        direction = ray.direction.normalize.reflect(hit.normal) + Vec3.random_unit(rng) * @fuzz
        direction.dot(hit.normal).positive? ? [Ray.new(hit.point, direction), @color] : nil
      when :dielectric
        ratio = hit.front_face ? 1.0 / @index : @index
        cosine = [-ray.direction.normalize.dot(hit.normal), 1.0].min
        sine = Math.sqrt(1.0 - cosine * cosine)
        cannot_refract = ratio * sine > 1
        reflectance = ((1 - ratio) / (1 + ratio))**2
        reflectance += (1 - reflectance) * (1 - cosine)**5
        direction = cannot_refract || reflectance > rng.rand ? ray.direction.reflect(hit.normal) : ray.direction.refract(hit.normal, ratio)
        [Ray.new(hit.point, direction), Vec3.new(1, 1, 1)]
      else nil
      end
    end
  end

  class Camera
    attr_reader :origin, :horizontal, :vertical, :lower_left
    def initialize(from: [13, 2, 3], to: [0, 0, 0], up: [0, 1, 0], fov: 20, aspect: 16.0 / 9, aperture: 0, focus_distance: 10)
      @origin = vec(from)
      fov, aspect, aperture, focus_distance = [fov, aspect, aperture, focus_distance].map { |value| Float(value) }
      raise ArgumentError, "camera fov must be between 0 and 180 degrees" unless fov.positive? && fov < 180
      raise ArgumentError, "camera aspect must be finite and positive" unless aspect.finite? && aspect.positive?
      raise ArgumentError, "camera focus distance must be finite and positive" unless focus_distance.finite? && focus_distance.positive?
      raise ArgumentError, "camera aperture must be finite and non-negative" unless aperture.finite? && !aperture.negative?
      theta = fov * Math::PI / 180
      viewport_height = 2 * Math.tan(theta / 2)
      viewport_width = aspect * viewport_height
      forward = (vec(to) - @origin).normalize
      raise ArgumentError, "camera target must differ from origin" if forward.near_zero?
      right = forward.cross(vec(up)).normalize
      raise ArgumentError, "camera up must not be parallel to view direction" if right.near_zero?
      camera_up = right.cross(forward)
      @horizontal = right * (focus_distance * viewport_width)
      @vertical = camera_up * (focus_distance * viewport_height)
      @lower_left = @origin - @horizontal / 2 - @vertical / 2 + forward * focus_distance
      @lens_radius = aperture / 2
      @right, @up = right, camera_up
    end

    def ray(u, v, rng)
      offset = random_disk(rng) * @lens_radius
      Ray.new(@origin + @right * offset.x + @up * offset.y, @lower_left + @horizontal * u + @vertical * v - @origin - @right * offset.x - @up * offset.y)
    end

    private

    def vec(value)
      value.is_a?(Vec3) ? value : Vec3.new(*value)
    end

    def random_disk(rng)
      loop do
        point = Vec3.new(rng.rand(-1.0...1.0), rng.rand(-1.0...1.0), 0)
        return point if point.dot(point) < 1
      end
    end
  end

  class Scene
    attr_accessor :camera, :sky
    attr_reader :objects

    def initialize
      @objects = []
      @camera = Camera.new
      @sky = true
      @bvh = nil
    end

    def self.build(&block)
      scene = new
      scene.instance_eval(&block)
      scene
    end

    def camera(**options)
      return @camera if options.empty?
      @camera = Camera.new(**options.merge(aspect: options.fetch(:aspect, 16.0 / 9)))
    end
    def background(sky: true) = (@sky = sky)
    def objects=(objects)
      @objects = objects
      @bvh = nil
    end

    def sphere(center:, radius:, material:)
      add_object(Sphere.new(center: vec(center), radius: radius, material: material))
    end

    def plane(point:, normal:, material:)
      add_object(Plane.new(point: vec(point), normal: vec(normal), material: material))
    end

    def triangle(a:, b:, c:, material:)
      add_object(Triangle.new(a: vec(a), b: vec(b), c: vec(c), material: material))
    end

    def quad(a:, b:, c:, d:, material:)
      add_object(Quad.new(a: vec(a), b: vec(b), c: vec(c), d: vec(d), material: material))
    end

    def hit(ray, minimum, maximum)
      rebuild_acceleration! if @bvh_objects != @objects
      candidates = []
      candidates << @bvh.hit(ray, minimum, maximum) if @bvh
      candidates.concat(@unbounded_objects.filter_map { |object| object.hit(ray, minimum, maximum) })
      candidates.compact.min_by(&:t)
    end

    def rebuild_acceleration!
      bounded, @unbounded_objects = @objects.partition { |object| object.respond_to?(:bounding_box) }
      @bvh = bounded.empty? ? nil : BvhNode.new(bounded)
      @bvh_objects = @objects.dup
    end
    def lambertian(color = [0.5, 0.5, 0.5]) = Material.new(color: color.respond_to?(:value) ? color : vec(color), kind: :lambertian)
    def metal(color = [0.8, 0.8, 0.8], fuzz: 0) = Material.new(color: vec(color), fuzz: fuzz, kind: :metal)
    def dielectric(index = 1.5) = Material.new(index: index, kind: :dielectric)
    def diffuse_light(color) = Material.new(emission: vec(color), kind: :light)
    def checker(first, second, scale: 1) = Texture.new(first: vec(first), second: vec(second), scale: scale)
    def image_texture(path, scale: 1) = ImageTexture.from_file(path, scale: scale)
    def noise_texture(scale: 1, seed: 42) = NoiseTexture.new(scale: scale, seed: seed)

    private

    def vec(value)
      value.is_a?(Vec3) ? value : Vec3.new(*value)
    end

    def add_object(object)
      @objects << object
      @bvh = nil
      object
    end
  end

  class Texture
    def initialize(first:, second:, scale: 1) = (@first, @second, @scale = first, second, scale)
    def value(point) = ((Math.sin(point.x * @scale * Math::PI) * Math.sin(point.z * @scale * Math::PI)).negative? ? @second : @first)
  end

  class ImageTexture
    def initialize(image:, scale: 1)
      @image, @scale = image, Float(scale)
      raise ArgumentError, "image texture scale must be positive" unless @scale.positive?
    end

    def self.from_file(path, scale: 1)
      new(image: Tessel.read(path), scale: scale)
    end

    def value(point)
      return Vec3.new(0, 0, 0) if @image.width.zero? || @image.height.zero?

      u = (point.x * @scale).floor % @image.width
      v = (point.z * @scale).floor % @image.height
      red, green, blue, = @image[u, v]
      Vec3.new(red / 255.0, green / 255.0, blue / 255.0)
    end
  end

  class Rng
    def initialize(seed = 42) = (@random = Random.new(seed))
    def rand(*args) = @random.rand(*args)
  end

  class Perlin
    def initialize(seed = 42)
      rng = Rng.new(seed)
      @vectors = Array.new(256) { Vec3.random_unit(rng) }
      @x = permutation(rng)
      @y = permutation(rng)
      @z = permutation(rng)
    end

    def noise(point)
      cell = [point.x.floor, point.y.floor, point.z.floor]
      fraction = [point.x - cell[0], point.y - cell[1], point.z - cell[2]]
      smooth = fraction.map { |value| value * value * (3 - 2 * value) }
      value = 0.0
      2.times do |i|
        2.times do |j|
          2.times do |k|
            index = @x[(cell[0] + i) & 255] ^ @y[(cell[1] + j) & 255] ^ @z[(cell[2] + k) & 255]
            weight = Vec3.new(fraction[0] - i, fraction[1] - j, fraction[2] - k)
            blend = (i.zero? ? 1 - smooth[0] : smooth[0]) * (j.zero? ? 1 - smooth[1] : smooth[1]) * (k.zero? ? 1 - smooth[2] : smooth[2])
            value += blend * @vectors[index].dot(weight)
          end
        end
      end
      value
    end

    def turbulence(point, depth: 7)
      weight = 1.0
      result = 0.0
      depth.times do
        result += weight * noise(point)
        weight *= 0.5
        point *= 2
      end
      result.abs
    end

    private

    def permutation(rng)
      values = (0...256).to_a
      255.downto(1) do |index|
        swap = rng.rand(index + 1)
        values[index], values[swap] = values[swap], values[index]
      end
      values
    end
  end

  class NoiseTexture
    def initialize(scale: 1, seed: 42)
      @scale = Float(scale)
      raise ArgumentError, "noise texture scale must be finite and positive" unless @scale.finite? && @scale.positive?
      @noise = Perlin.new(seed)
    end

    def value(point)
      value = 0.5 * (1.0 + Math.sin(@scale * point.z + 10.0 * @noise.turbulence(point * @scale)))
      Vec3.new(value, value, value)
    end
  end

  module Renderer
    module_function

    def render(scene, width:, height:, spp:, max_depth:, seed: 42, progress: nil)
      Tessel::Image.from_rgba(width, height, render_rows(scene, width: width, height: height, y_range: 0...height, spp: spp, max_depth: max_depth, seed: seed, progress: progress))
    end

    def render_rows(scene, width:, height:, y_range:, spp:, max_depth:, seed:, progress: nil)
      raise ArgumentError, "dimensions, spp and max_depth must be positive" unless [width, height, spp, max_depth].all? { |value| value.is_a?(Integer) && value.positive? }
      data = "".b
      scene.rebuild_acceleration!
      y_range.each do |y|
        (0...width).each do |x|
          rng = Rng.new(seed ^ ((y * width + x) * 0x9e37_79b9))
          color = Vec3.new
          spp.times do
            ray = scene.camera.ray((x + rng.rand) / width.to_f, (height - 1 - y + rng.rand) / height.to_f, rng)
            color += trace(ray, scene, rng, max_depth)
          end
          color = color / spp
          data << [Math.sqrt(color.x.clamp(0, 1)), Math.sqrt(color.y.clamp(0, 1)), Math.sqrt(color.z.clamp(0, 1))].map { |channel| (channel * 255.999).to_i }.push(255).pack("C4")
        end
        progress.call(y + 1, height) if progress
      end
      data
    end

    def trace(ray, scene, rng, depth)
      attenuation = Vec3.new(1, 1, 1)
      depth.times do
        hit = scene.hit(ray, 0.001, Float::INFINITY)
        return attenuation * background(ray, scene) unless hit
        return attenuation * hit.material.emission if hit.material.emission.dot(hit.material.emission).positive?
        scattered = hit.material.scatter(ray, hit, rng)
        return Vec3.new unless scattered
        ray, color = scattered
        attenuation *= color
      end
      Vec3.new
    end

    def background(ray, scene)
      return Vec3.new(0.0, 0.0, 0.0) unless scene.sky
      t = 0.5 * (ray.direction.normalize.y + 1)
      Vec3.new(1, 1, 1) * (1 - t) + Vec3.new(0.5, 0.7, 1.0) * t
    end
    private_class_method :trace, :background
  end

  class Accumulator
    attr_reader :samples
    def initialize(width, height)
      @width, @height = Integer(width), Integer(height)
      raise ArgumentError, "accumulator dimensions must be positive" unless @width.positive? && @height.positive?

      @image = Array.new(@width * @height) { Vec3.new }
      @samples = 0
    end

    def add(image)
      raise ArgumentError, "accumulator image dimensions do not match" unless image.width == @width && image.height == @height

      image.bytes.bytes.each_slice(4).with_index { |(r, g, b, _a), index| @image[index] += Vec3.new(r / 255.0, g / 255.0, b / 255.0) }
      @samples += 1
      Tessel::Image.from_rgba(@width, @height, @image.flat_map { |color| value = color / @samples; [value.x * 255, value.y * 255, value.z * 255, 255].map(&:to_i) }.pack("C*"))
    end
  end

  module Engines
    module Parallel
      module_function

      def render(scene, width:, height:, spp:, max_depth:, seed:, workers:, progress: nil)
        return Renderer.render(scene, width: width, height: height, spp: spp, max_depth: max_depth, seed: seed, progress: progress) unless Process.respond_to?(:fork) && RUBY_PLATFORM !~ /mswin|mingw/ && workers > 1

        chunk = (height + workers - 1) / workers
        jobs = (0...height).each_slice(chunk).map { |rows| rows.first..rows.last }
        children = []
        jobs.each do |range|
          reader, writer = IO.pipe
          pid = Process.fork do
            reader.close
            begin
              writer.write(Renderer.render_rows(scene, width: width, height: height, y_range: range, spp: spp, max_depth: max_depth, seed: seed))
              writer.close
              exit! 0
            rescue StandardError
              writer.close
              exit! 1
            end
          end
          writer.close
          children << [reader, pid, range]
        end
        completed = 0
        readers = children.map do |reader, pid, range|
          Thread.new { [reader.read, reader, pid, range] }
        end
        data = readers.map do |thread|
          bytes, reader, pid, range = thread.value
          reader.close
          _, status = Process.waitpid2(pid)
          raise Error, "render worker failed" unless status.success? && bytes.bytesize == range.size * width * 4
          completed += 1
          progress.call(completed, jobs.length) if progress
          bytes
        end.join
        Tessel::Image.from_rgba(width, height, data)
      ensure
        readers&.each(&:join)
        children&.each do |reader, pid, _range|
          reader.close unless reader.closed?
          Process.waitpid(pid)
        rescue Errno::ECHILD
          nil
        end
      end
    end

    module ShaderCodegen
      module_function
      def generate(scene, max_objects: 500)
        raise ArgumentError, "shader engine supports at most #{max_objects} objects" if scene.objects.length > max_objects
        unless scene.objects.all? { |object| object.is_a?(Sphere) && object.material.color.is_a?(Vec3) && object.material.kind == :lambertian }
          raise UnsupportedError, "RLSL codegen supports spheres with constant-color Lambertian materials only"
        end

        camera = scene.camera
        lines = [
          "|frag_coord, resolution, uniforms|",
          "origin = #{vector(camera.origin)}",
          "sample = 0",
          "radiance = vec3(0.0, 0.0, 0.0)",
          "while sample < uniforms.spp",
          "  jitter_x = fract(sin(frag_coord.x + sample + uniforms.seed + 1.0) * 43758.5453)",
          "  jitter_y = fract(sin(frag_coord.y + sample + uniforms.seed + 2.0) * 43758.5453)",
          "  sample_u = (frag_coord.x + jitter_x) / resolution.x",
          "  sample_v = (frag_coord.y + jitter_y) / resolution.y",
          "  ray_origin = origin",
          "  ray_direction = #{vector(camera.lower_left)} + #{vector(camera.horizontal)} * sample_u + #{vector(camera.vertical)} * sample_v - ray_origin",
          "  throughput = vec3(1.0, 1.0, 1.0)",
          "  depth = 0",
          "  while depth < uniforms.max_depth",
          "    closest = 1000000000.0",
          "    hit = false",
          "    hit_point = vec3(0.0, 0.0, 0.0)",
          "    hit_normal = vec3(0.0, 1.0, 0.0)",
          "    hit_color = vec3(0.0, 0.0, 0.0)"
        ]
        scene.objects.each_with_index do |object, index|
          center = vector(object.center)
          color = vector(object.material.color)
          lines.concat([
            "center_#{index} = #{center}",
            "offset_#{index} = ray_origin - center_#{index}",
            "half_b_#{index} = dot(offset_#{index}, ray_direction)",
            "a_#{index} = dot(ray_direction, ray_direction)",
            "discriminant_#{index} = half_b_#{index} * half_b_#{index} - a_#{index} * (dot(offset_#{index}, offset_#{index}) - #{float(object.radius * object.radius)})",
            "if discriminant_#{index} >= 0.0",
            "  root_#{index} = (-half_b_#{index} - sqrt(discriminant_#{index})) / a_#{index}",
            "  if root_#{index} <= 0.001 || root_#{index} >= closest",
            "    root_#{index} = (-half_b_#{index} + sqrt(discriminant_#{index})) / a_#{index}",
            "  end",
            "  if root_#{index} > 0.001 && root_#{index} < closest",
            "    closest = root_#{index}",
            "    hit = true",
            "    hit_point = ray_origin + ray_direction * root_#{index}",
            "    hit_normal = normalize(hit_point - center_#{index})",
            "    hit_color = #{color}",
            "  end",
            "end"
          ])
        end
        lines.concat([
          "    if hit",
          "      scatter_x = fract(sin(frag_coord.x + sample + depth + uniforms.seed + 3.0) * 43758.5453) * 2.0 - 1.0",
          "      scatter_y = fract(sin(frag_coord.y + sample + depth + uniforms.seed + 4.0) * 43758.5453) * 2.0 - 1.0",
          "      scatter_z = fract(sin(frag_coord.x + frag_coord.y + sample + depth + uniforms.seed + 5.0) * 43758.5453) * 2.0 - 1.0",
          "      scatter = normalize(vec3(scatter_x, scatter_y, scatter_z))",
          "      ray_origin = hit_point",
          "      ray_direction = normalize(hit_normal + scatter)",
          "      throughput = throughput * hit_color",
          "    else",
          "      unit_direction = normalize(ray_direction)",
          scene.sky ? "      background_t = 0.5 * (unit_direction.y + 1.0)" : "      background_t = 0.0",
          scene.sky ? "      radiance += throughput * (vec3(1.0, 1.0, 1.0) * (1.0 - background_t) + vec3(0.5, 0.7, 1.0) * background_t)" : "      radiance += throughput * vec3(0.0, 0.0, 0.0)",
          "      depth = uniforms.max_depth",
          "    end",
          "    depth += 1",
          "  end",
          "  sample += 1",
          "end",
          "radiance / (uniforms.spp + 0.0)"
        ])
        lines.join("\n")
      end

      def vector(value) = "vec3(#{value.to_a.map { |component| float(component) }.join(', ')})"
      private_class_method :vector

      def float(value)
        format("%.9f", Float(value))
      end
      private_class_method :float
    end

    module RlslC
      module_function

      def render(scene, width:, height:, spp:, max_depth:, seed:)
        begin
          require "rlsl"
        rescue LoadError => error
          raise UnsupportedError, "RLSL is required for the :rlsl_c engine: #{error.message}"
        end

        builder = RLSL::ShaderBuilder.new(:caustics_scene)
        builder.uniforms { int :spp; int :max_depth; int :seed }
        builder.fragment_source(ShaderCodegen.generate(scene))
        shader = builder.compile_and_load
        bgra = "\0".b * (width * height * 4)
        shader.render(bgra, width, height, spp: spp, max_depth: max_depth, seed: seed)
        rgba = bgra.bytes.each_slice(4).flat_map { |blue, green, red, alpha| [red, green, blue, alpha] }.pack("C*")
        Tessel::Image.from_rgba(width, height, rgba)
      end
    end

    module Metal
      module_function

      def render(scene, width:, height:, spp:, max_depth:, seed:)
        begin
          require "metaco"
          require "rlsl"
          Metaco.init
          handle = Metaco.window_create(width, height, "Caustics")
          raise UnsupportedError, "Metal is not available" unless Metaco.metal_compute_available?(handle)

          builder = RLSL::ShaderBuilder.new(:caustics_metal_scene)
          builder.uniforms { int :spp; int :max_depth; int :seed }
          builder.fragment_source(ShaderCodegen.generate(scene))
          shader = builder.build_metal_shader
          shader.render_metal(handle, width, height, { spp: spp, max_depth: max_depth, seed: seed })
          Tessel::Image.from_rgba(width, height, Metaco.read_pixels(handle, source: :compute))
        rescue LoadError => error
          raise UnsupportedError, "Metaco and RLSL are required for the :metal engine: #{error.message}"
        ensure
          Metaco.window_destroy(handle) if handle
        end
      end
    end
  end

  module_function

  def preview(scene, width:, height:, spp: 16, max_depth: 8, seed: 42, backend: :auto, output: nil)
    require "rbgl"
    spp = Integer(spp)
    raise ArgumentError, "preview spp must be positive" unless spp.positive?

    window = RBGL::GUI::Window.new(width: width, height: height, title: "caustics", backend: backend)
    accumulator = Accumulator.new(width, height)
    image = Tessel::Image.new(width, height)
    paused = false
    until window.should_close?
      events = Array(window.poll_events_raw)
      events.each do |event|
        key = event[:key]&.to_sym
        character = event[:char]
        if key == :close || key == :escape || character == "\u0003"
          window.close
        elsif key == :space || character == " "
          paused = !paused
        elsif character == "+" || character == "="
          spp += 1
        elsif character == "-"
          spp = [spp - 1, 1].max
        elsif %w[s S].include?(character)
          image.write(output) if output
        end
      end
      break if window.should_close?
      unless paused || accumulator.samples >= spp
        image = accumulator.add(render(scene, width: width, height: height, spp: 1, max_depth: max_depth, seed: seed + accumulator.samples))
        window.set_pixels(image.bytes)
      end
      sleep(0.01) if paused || accumulator.samples >= spp
    end
    image.write(output) if output
    image
  ensure
    window&.close
  end

  def render(scene, width:, height:, spp: 1, max_depth: 8, engine: :ruby, workers: 1, seed: 42, progress: nil)
    workers = Integer(workers)
    seed = Integer(seed)
    raise ArgumentError, "workers must be positive" unless workers.positive?
    raise ArgumentError, "dimensions, spp and max_depth must be positive" unless [width, height, spp, max_depth].all? { |value| value.is_a?(Integer) && value.positive? }
    raise ArgumentError, "progress must respond to call" if progress && !progress.respond_to?(:call)
    case engine.to_sym
    when :ruby then Engines::Parallel.render(scene, width: width, height: height, spp: spp, max_depth: max_depth, workers: workers, seed: seed, progress: progress)
    when :rlsl_c then Engines::RlslC.render(scene, width: width, height: height, spp: spp, max_depth: max_depth, seed: seed)
    when :metal then Engines::Metal.render(scene, width: width, height: height, spp: spp, max_depth: max_depth, seed: seed)
    else raise ArgumentError, "unknown engine: #{engine}"
    end
  end

  def benchmark(scene, engines: [:ruby], width: 64, height: 36, spp: 1, max_depth: 4)
    engines.to_h do |engine|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      render(scene, width: width, height: height, spp: spp, max_depth: max_depth, engine: engine)
      [engine, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end
  end

  def vec(value)
    value.is_a?(Vec3) ? value : Vec3.new(*value)
  end
  private_class_method :vec
end
