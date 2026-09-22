# frozen_string_literal: true

require "caustics"

SCENE = Caustics::Scene.build do
  camera from: [3, 2, 2], to: [0, 0, -1], fov: 45
  sphere center: [0, -100.5, -1], radius: 100, material: lambertian(checker([0.2, 0.3, 0.1], [0.9, 0.9, 0.9], scale: 0.32))
  sphere center: [0, 0, -1], radius: 0.5, material: lambertian([0.7, 0.3, 0.3])
  sphere center: [-1, 0, -1], radius: 0.5, material: dielectric(1.5)
  sphere center: [1, 0, -1], radius: 0.5, material: metal([0.8, 0.8, 0.8], fuzz: 0.1)
end
