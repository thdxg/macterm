@testable import Macterm
import Testing

@MainActor
struct ExperimentShadersTests {
    // MARK: - Encoding: the framebuffer contract read off the user's config

    @Test
    func no_config_is_macos_defaults() {
        #expect(ExperimentShaders.Encoding.from(userConfigText: nil) == .macOSDefault)
        #expect(ExperimentShaders.Encoding.from(userConfigText: "font-size = 16\n") == .macOSDefault)
        #expect(ExperimentShaders.Encoding.macOSDefault == .init(linearBlending: false, displayP3: false))
    }

    @Test
    func linear_and_linear_corrected_both_mean_a_linear_framebuffer() {
        #expect(ExperimentShaders.Encoding.from(userConfigText: "alpha-blending = linear\n").linearBlending)
        #expect(ExperimentShaders.Encoding.from(userConfigText: "alpha-blending = linear-corrected\n").linearBlending)
        #expect(!ExperimentShaders.Encoding.from(userConfigText: "alpha-blending = native\n").linearBlending)
    }

    @Test
    func display_p3_is_read_and_last_value_wins() {
        let text = "window-colorspace = display-p3\nalpha-blending = linear\nalpha-blending = native\n"
        let encoding = ExperimentShaders.Encoding.from(userConfigText: text)
        #expect(encoding == .init(linearBlending: false, displayP3: true))
    }

    @Test
    func unknown_values_fall_back_like_ghosttys_parser_rejecting_them() {
        let encoding = ExperimentShaders.Encoding.from(userConfigText: "alpha-blending = bogus\nwindow-colorspace = rec2020\n")
        #expect(encoding == .macOSDefault)
    }

    // MARK: - Rendering

    @Test
    func header_carries_both_defines_and_the_template_is_untouched() {
        let template = "// body\nvoid mainImage() {}\n"
        let rendered = ExperimentShaders.render(
            template: template,
            encoding: .init(linearBlending: true, displayP3: true)
        )
        #expect(rendered == "#define MACTERM_LINEAR_BLENDING 1\n#define MACTERM_DISPLAY_P3 1\n" + template)
    }

    @Test
    func trail_is_installed_before_glide_so_it_renders_beneath() {
        #expect(ExperimentShaders.fileNames == ["cursor_trail.glsl", "cursor_glide.glsl"])
    }
}
