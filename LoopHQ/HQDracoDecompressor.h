#import <Foundation/Foundation.h>
#import <GLTFKit2/GLTFKit2.h>

NS_ASSUME_NONNULL_BEGIN

/// Draco mesh decompression plugin for GLTFKit2.
///
/// Google's photorealistic 3D tiles are glTF binaries whose meshes are all
/// KHR_draco_mesh_compression-encoded; GLTFKit2 delegates decompression to a
/// class registered by name (`GLTFAsset.dracoDecompressorClassName =
/// "HQDracoDecompressor"`). The implementation links the Draco C++ decoder
/// from the DracoSwift package. Adapted from GLTFKit2's MIT-licensed
/// SampleDracoPlugin (github.com/warrenm/GLTFKit2).
@interface HQDracoDecompressor : NSObject <GLTFDracoMeshDecompressor>

+ (GLTFPrimitive *)newPrimitiveForCompressedBufferView:(GLTFBufferView *)bufferView
                                          attributeMap:(NSDictionary<NSString *, NSNumber *> *)attributes;

@end

NS_ASSUME_NONNULL_END
