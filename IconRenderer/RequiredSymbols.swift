import Foundation

/// The private symbols `macterm-icon-renderer` calls, checked before the first
/// call. The helper links the private frameworks weakly, so a symbol that this
/// macOS does not have is nil instead of a dyld abort at launch. The check then
/// names every missing symbol in one exit (`apiMissing`), and the app keeps the
/// bundled icon.
///
/// The Swift symbols are the ones in `PrivateInterfaces/IconRendering.tbd`,
/// without the leading underscore. `IconRendererSymbolsTests` keeps the two
/// lists the same.
enum RequiredSymbols {
    static let swift = [
        "$s13IconRendering09FinalizedA0V08renderedA04withSo10CGImageRefaSgAA19GlobalConfigurationV_tF",
        "$s13IconRendering09FinalizedA0V10ScaledSizeV6points5scaleAESo6CGSizeV_SitcfC",
        "$s13IconRendering09FinalizedA0V10ScaledSizeVMa",
        "$s13IconRendering09FinalizedA0V13ConfigurationV4icon5style18parametersOverrideAeA0A0V_AA12ICRIconStyleVAA22ICRRenderingParametersVSgtcfC",
        "$s13IconRendering09FinalizedA0V13ConfigurationVMa",
        "$s13IconRendering09FinalizedA0V6config4sizeA2C13ConfigurationV_AC10ScaledSizeVtcfC",
        "$s13IconRendering09FinalizedA0VMa",
        "$s13IconRendering0A0V17GradientPlacementV5start3endAESo7CGPointV_AItcfC",
        "$s13IconRendering0A0V17GradientPlacementVMa",
        "$s13IconRendering0A0V17GradientPlacementVMn",
        "$s13IconRendering0A0V4FillV5solidyAeA0A5ColorVFZ",
        "$s13IconRendering0A0V4FillV8gradient5start3end9placementAeA0A5ColorV_AkC17GradientPlacementVSgtFZ",
        "$s13IconRendering0A0V4FillVMa",
        "$s13IconRendering0A0V4FillVMn",
        "$s13IconRendering0A0V5LayerV8elementsSayAC7ElementVGvg",
        "$s13IconRendering0A0V5LayerV8elementsSayAC7ElementVGvs",
        "$s13IconRendering0A0V5LayerVMa",
        "$s13IconRendering0A0V5LayerVMn",
        "$s13IconRendering0A0V6layersSayAC5LayerVGvg",
        "$s13IconRendering0A0V6layersSayAC5LayerVGvs",
        "$s13IconRendering0A0V7ElementV4fillAC4FillVSgvs",
        "$s13IconRendering0A0V7ElementVMa",
        "$s13IconRendering0A0V7ElementVMn",
        "$s13IconRendering0A0V7chicletAC4FillVvs",
        "$s13IconRendering0A0VMa",
        "$s13IconRendering0A5ColorV3red5green4blue5alphaACSd_S3dtcfC",
        "$s13IconRendering0A5ColorVMa",
        "$s13IconRendering0B4ModeV5colorACvgZ",
        "$s13IconRendering0B4ModeVMa",
        "$s13IconRendering12ICRIconStyleV16SystemAppearanceO4darkyA2EmFWC",
        "$s13IconRendering12ICRIconStyleV16SystemAppearanceO5lightyA2EmFWC",
        "$s13IconRendering12ICRIconStyleV16SystemAppearanceOMa",
        "$s13IconRendering12ICRIconStyleV8platform10appearance13renderingModeAcA0C8PlatformO_AC16SystemAppearanceOAA0bH0VtcfC",
        "$s13IconRendering12ICRIconStyleVMa",
        "$s13IconRendering15ICRIconPlatformO4mainyA2CmFWC",
        "$s13IconRendering15ICRIconPlatformOMa",
        "$s13IconRendering19GlobalConfigurationVACycfC",
        "$s13IconRendering19GlobalConfigurationVMa",
        "$s13IconRendering22ICRRenderingParametersVMa",
        "$s13IconRendering22ICRRenderingParametersVMn",
        "$sSo22CUINamedIconLayerStackC0B9RenderingE04makeB0AC0B0VyKF",
    ]

    /// The CoreUI classes in `PrivateInterfaces/CoreUI.tbd`.
    static let objcClasses = ["CUICatalog", "CUINamedIconLayerStack", "CUINamedLookup"]

    /// Each symbol and class that this process cannot find.
    static func missing() -> [String] {
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        let symbols = swift.filter { dlsym(everywhere, $0) == nil }
        let classes = objcClasses.filter { NSClassFromString($0) == nil }
        return symbols + classes
    }
}
