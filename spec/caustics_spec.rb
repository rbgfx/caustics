# frozen_string_literal: true

RSpec.describe Caustics do
  it "has a version number" do
    expect(Caustics::VERSION).not_to be nil
  end

  it "renders a deterministic small scene" do
    scene = Caustics::Scene.build do
      camera from: [0, 0, 3], to: [0, 0, 0], fov: 45
      background sky: true
      sphere center: [0, 0, 0], radius: 0.5, material: lambertian([0.8, 0.2, 0.2])
    end

    first = Caustics.render(scene, width: 8, height: 4, spp: 2, max_depth: 2, seed: 9)
    second = Caustics.render(scene, width: 8, height: 4, spp: 2, max_depth: 2, seed: 9)

    expect(first.bytes).to eq(second.bytes)
  end

  it "computes sphere hits" do
    sphere = Caustics::Sphere.new(center: Caustics::Vec3.new, radius: 1, material: Caustics::Material.new)
    hit = sphere.hit(Caustics::Ray.new(Caustics::Vec3.new(0, 0, 3), Caustics::Vec3.new(0, 0, -1)), 0.001, Float::INFINITY)

    expect(hit.t).to eq(2.0)
  end

  it "matches linear sphere hits through the BVH" do
    scene = Caustics::Scene.new
    scene.sphere center: [0, 0, 0], radius: 0.5, material: Caustics::Material.new
    scene.sphere center: [3, 0, 0], radius: 0.5, material: Caustics::Material.new
    scene.sphere center: [-3, 0, 0], radius: 0.5, material: Caustics::Material.new
    scene.sphere center: [0, 3, 0], radius: 0.5, material: Caustics::Material.new
    ray = Caustics::Ray.new(Caustics::Vec3.new(0, 0, 3), Caustics::Vec3.new(0, 0, -1))

    expected = scene.objects.filter_map { |object| object.hit(ray, 0.001, Float::INFINITY) }.min_by(&:t)
    expect(scene.hit(ray, 0.001, Float::INFINITY)&.t).to eq(expected&.t)
  end

  it "rejects degenerate spheres" do
    expect { Caustics::Sphere.new(center: Caustics::Vec3.new, radius: 0, material: Caustics::Material.new) }
      .to raise_error(ArgumentError, /radius must be positive/)
    expect { Caustics::Material.new(index: 0) }
      .to raise_error(ArgumentError, /refractive index must be positive/)
  end

  it "rejects invalid camera bases" do
    expect { Caustics::Camera.new(from: [0, 0, 0], to: [0, 0, 0]) }
      .to raise_error(ArgumentError, /target must differ/)
    expect { Caustics::Camera.new(from: [0, 0, 1], to: [0, 0, 0], up: [0, 0, 1]) }
      .to raise_error(ArgumentError, /parallel to view direction/)
  end

  it "hits planes, triangles, and quads" do
    material = Caustics::Material.new
    ray = Caustics::Ray.new(Caustics::Vec3.new(0, 0, 1), Caustics::Vec3.new(0, 0, -1))
    plane = Caustics::Plane.new(point: Caustics::Vec3.new, normal: Caustics::Vec3.new(0, 0, 1), material: material)
    triangle = Caustics::Triangle.new(a: Caustics::Vec3.new(-1, -1, 0), b: Caustics::Vec3.new(1, -1, 0), c: Caustics::Vec3.new(0, 1, 0), material: material)
    quad = Caustics::Quad.new(a: Caustics::Vec3.new(-1, -1, 0), b: Caustics::Vec3.new(1, -1, 0), c: Caustics::Vec3.new(1, 1, 0), d: Caustics::Vec3.new(-1, 1, 0), material: material)

    expect(plane.hit(ray, 0.001, Float::INFINITY).t).to eq(1.0)
    expect(triangle.hit(ray, 0.001, Float::INFINITY).t).to eq(1.0)
    expect(quad.hit(ray, 0.001, Float::INFINITY).t).to eq(1.0)
  end

  it "combines bounded and unbounded scene objects" do
    scene = Caustics::Scene.new
    material = Caustics::Material.new
    scene.plane(point: [0, 0, 0], normal: [0, 0, 1], material: material)
    scene.sphere(center: [0, 0, -1], radius: 0.25, material: material)
    ray = Caustics::Ray.new(Caustics::Vec3.new(0, 0, 1), Caustics::Vec3.new(0, 0, -1))

    expect(scene.hit(ray, 0.001, Float::INFINITY).t).to be_within(1e-10).of(1.0)
  end

  it "renders the same pixels with one or multiple workers" do
    scene = Caustics::Scene.build { sphere center: [0, 0, 0], radius: 0.5, material: lambertian([0.8, 0.2, 0.2]) }
    single = Caustics.render(scene, width: 4, height: 3, spp: 2, workers: 1, seed: 7)
    parallel = Caustics.render(scene, width: 4, height: 3, spp: 2, workers: 2, seed: 7)
    expect(parallel.bytes).to eq(single.bytes)
  end

  it "reports completed parallel tiles" do
    scene = Caustics::Scene.new
    progress = []
    Caustics.render(scene, width: 4, height: 4, spp: 1, workers: 2, progress: ->(completed, total) { progress << [completed, total] })

    expect(progress).to eq([[1, 2], [2, 2]])
  end

  it "handles one-pixel images and rejects unsupported shader materials" do
    scene = Caustics::Scene.new
    expect(Caustics.render(scene, width: 1, height: 1).bytes.bytesize).to eq(4)
    textured = Caustics::Scene.build do
      sphere center: [0, 0, 0], radius: 1, material: lambertian(checker([1, 0, 0], [0, 1, 0]))
    end
    expect { Caustics::Engines::ShaderCodegen.generate(textured) }
      .to raise_error(Caustics::UnsupportedError, /constant-color Lambertian/)
  end

  it "generates RLSL source for constant-colored spheres" do
    scene = Caustics::Scene.build do
      camera from: [0, 0, 3], to: [0, 0, 0]
      sphere center: [0, 0, 0], radius: 0.5, material: lambertian([1, 0, 0])
    end

    source = Caustics::Engines::ShaderCodegen.generate(scene)
    expect(source).to include("center_0 = vec3(0.000000000, 0.000000000, 0.000000000)")
    expect(source).to include("color")
    expect(source).to include("while sample < uniforms.spp")
  end

  it "uses checker textures as diffuse material colors" do
    scene = Caustics::Scene.build do
      sphere center: [0, 0, 0], radius: 1, material: lambertian(checker([1, 0, 0], [0, 0, 1]))
    end
    expect(Caustics.render(scene, width: 2, height: 2, spp: 1).bytes.bytesize).to eq(16)
  end

  it "samples image textures from repeatable point coordinates" do
    image = Tessel::Image.from_rgba(2, 1, [255, 0, 0, 255, 0, 255, 0, 255].pack("C*"))
    texture = Caustics::ImageTexture.new(image: image)

    expect(texture.value(Caustics::Vec3.new(0.1, 0, 0)).to_a).to eq([1.0, 0.0, 0.0])
    expect(texture.value(Caustics::Vec3.new(1.1, 0, 0)).to_a).to eq([0.0, 1.0, 0.0])
    expect(Caustics::Scene.new.lambertian(texture).scatter(
      Caustics::Ray.new(Caustics::Vec3.new(0, 0, 1), Caustics::Vec3.new(0, 0, -1)),
      Caustics::Hit.new(point: Caustics::Vec3.new(0.1, 0, 0), normal: Caustics::Vec3.new(0, 0, 1),
                        t: 1, front_face: true, material: nil), Caustics::Rng.new
    ).last.to_a).to eq([1.0, 0.0, 0.0])
  end

  it "produces deterministic Perlin noise textures" do
    point = Caustics::Vec3.new(0.25, 0.5, 0.75)
    first = Caustics::NoiseTexture.new(seed: 7).value(point).to_a
    second = Caustics::NoiseTexture.new(seed: 7).value(point).to_a

    expect(first).to eq(second)
    expect(first.all? { |channel| channel.between?(0.0, 1.0) }).to be(true)
  end

  it "accumulates matching images and rejects mismatched dimensions" do
    accumulator = Caustics::Accumulator.new(1, 1)
    image = Tessel::Image.new(1, 1, fill: [128, 64, 32, 255])

    expect(accumulator.add(image)[0, 0]).to eq([128, 64, 32, 255])
    expect(accumulator.samples).to eq(1)
    expect { accumulator.add(Tessel::Image.new(2, 1)) }.to raise_error(ArgumentError, /dimensions/)
  end
end
