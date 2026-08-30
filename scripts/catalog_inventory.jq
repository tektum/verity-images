# Catalog inventory invariant, shared by catalog.yaml and test_build_catalog.sh.
# Input: [catalog, matrix]. Every catalog image must belong to an expected image,
# and an unexpected version may only remain while no expected version of the same
# image has been published yet. That keeps a version-authority change from pruning
# a live entry before its replacement build exists.
(.[1].include | map([.name, .tag_version])) as $expected
| .[0].images as $images
| all(
    $images[];
    . as $image
    | ($expected | any(. == [$image.name, $image.version]))
      or (
        ($expected | any(.[0] == $image.name))
        and (
          (
            $images
            | any(. as $other | $other.name == $image.name and ($expected | any(. == [$other.name, $other.version])))
          )
          | not
        )
      )
  )
