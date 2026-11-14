// Re-encode WebP textures inside a GLB as PNG (Godot 4.4 has no EXT_texture_webp).
const { NodeIO } = require('@gltf-transform/core');
const { ALL_EXTENSIONS } = require('@gltf-transform/extensions');
const sharp = require('sharp');

async function main() {
  const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
  const doc = await io.read(process.argv[2]);
  const root = doc.getRoot();
  let converted = 0;
  for (const tex of root.listTextures()) {
    const bytes = tex.getImage();
    if (!bytes) continue;
    const isWebp = bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[8] === 0x57;
    if (!isWebp) continue;
    const png = await sharp(Buffer.from(bytes)).png({ compressionLevel: 9 }).toBuffer();
    tex.setImage(new Uint8Array(png));
    tex.setMimeType('image/png');
    converted++;
  }
  for (const ext of root.listExtensionsUsed()) {
    if (ext.extensionName === 'EXT_texture_webp') {
      if (root.listTextures().every((t) => t.getMimeType() !== 'image/webp')) ext.dispose();
    }
  }
  for (const ext of root.listExtensionsRequired()) {
    if (ext.extensionName === 'EXT_texture_webp') ext.dispose();
  }
  await io.write(process.argv[3], doc);
  console.log(`  ${converted} webp -> png`);
}
main().catch((e) => { console.error(e); process.exit(1); });
