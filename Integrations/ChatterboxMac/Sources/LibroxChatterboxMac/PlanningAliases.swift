#if os(macOS)
import LibroxChatterboxPlanning

// Preserve the local renderer API while readers use the light planning product.
public typealias ChatterboxMacChapterRequest = ChatterboxChapterRenderOptions
public typealias ChatterboxMacRenderPlan = ChatterboxChapterRenderPlan
public typealias ChatterboxMacRenderPlanError = ChatterboxChapterRenderPlanError
#endif
