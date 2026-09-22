# Caustics shader checks

The RLSL engine uses generated, unrolled scalar expressions. The supported
shader subset is intentionally narrower than the Ruby renderer: constant
colored Lambertian spheres, deterministic sampling, and bounded bounce loops.

The code generator and its specs verify:

- generated fragment source builds through the RLSL C target;
- fixed loop bounds are represented by scalar `while` loops;
- sphere constants and indexed scene expansion are emitted without runtime
  Ruby objects;
- integer uniforms carry `spp`, `max_depth`, and `seed` into the generated
  shader;
- unsupported materials and object counts fail before compilation.

Struct and array heavy scene descriptions, arbitrary materials, and Ractor
workers remain outside this engine's supported subset. The Ruby and parallel
engines are the reference implementation for those cases.
