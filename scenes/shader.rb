# frozen_string_literal: true

require "caustics"

SCENE = Caustics::Scene.build do
  camera from: [0, 0, 3], to: [0, 0, 0], fov: 45
  sphere center: [0, 0, 0], radius: 0.75, material: lambertian([0.8, 0.2, 0.2])
end
