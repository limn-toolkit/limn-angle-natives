package limn.angle;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.lwjgl.PointerBuffer;
import org.lwjgl.egl.EGL;
import org.lwjgl.egl.EGL10;
import org.lwjgl.opengles.GLES;
import org.lwjgl.opengles.GLES30;
import org.lwjgl.opengles.GLESCapabilities;
import org.lwjgl.system.Configuration;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * What the toolkit asks of these libraries, asked of the ones this machine's build staged: an
 * OpenGL ES 3.0 context on the platform's one backend (Direct3D 11 or Metal), the extensions the
 * toolkit's capability gates need (its ADR 003 §4.4), a draw read back, and on macOS the IOSurface
 * binding its zero-copy video depends on. Loaded the way the toolkit's loader loads them: by full
 * path, libGLESv2 first.
 *
 * <p>No window: a pbuffer is enough to prove the libraries, and it runs on a runner with no desktop.
 * Skipped with a sentence where this machine's slice was not built.
 */
class AngleContextTest {

    private static final int EGL_PLATFORM_ANGLE_ANGLE = 0x3202;
    private static final int EGL_PLATFORM_ANGLE_TYPE_ANGLE = 0x3203;
    private static final int EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE = 0x3208;
    private static final int EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE = 0x3489;
    private static final int EGL_OPENGL_ES3_BIT = 0x40;
    private static final int EGL_CONTEXT_MAJOR_VERSION = 0x3098;

    private static long display;
    private static long surface;
    private static long context;
    private static GLESCapabilities capabilities;

    private static boolean macOs() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("mac");
    }

    @BeforeAll
    static void open() {
        Path dist = Path.of(System.getProperty("limn.angle.dist", "native/dist/limn/angle/native/none"));
        String suffix = macOs() ? ".dylib" : ".dll";
        Path gles = dist.resolve("libGLESv2" + suffix);
        Path egl = dist.resolve("libEGL" + suffix);
        Assumptions.assumeTrue(Files.isRegularFile(gles) && Files.isRegularFile(egl),
                "no ANGLE built for this machine under " + dist + " (run scripts/build-angle.sh or .ps1)");
        System.load(gles.toAbsolutePath().toString());
        System.load(egl.toAbsolutePath().toString());
        Configuration.EGL_LIBRARY_NAME.set(egl.toAbsolutePath().toString());
        Configuration.OPENGLES_LIBRARY_NAME.set(gles.toAbsolutePath().toString());

        try (MemoryStack stack = MemoryStack.stackPush()) {
            // The client extension rather than EGL 1.5's entry point: ANGLE's libEGL offers both, and
            // the extension is what the windowing library asks it through.
            IntBuffer attributes = stack.ints(EGL_PLATFORM_ANGLE_TYPE_ANGLE,
                    macOs() ? EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE : EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
                    EGL10.EGL_NONE);
            // Through its address: LWJGL fills its client capabilities from the client extension
            // string, and resolves the call only when that string names it.
            long getPlatformDisplay = EGL.getFunctionProvider().getFunctionAddress("eglGetPlatformDisplayEXT");
            assertTrue(getPlatformDisplay != 0, "libEGL exports no eglGetPlatformDisplayEXT");
            display = org.lwjgl.system.JNI.invokePPP(EGL_PLATFORM_ANGLE_ANGLE, 0L /* EGL_DEFAULT_DISPLAY */,
                    MemoryUtil.memAddress(attributes), getPlatformDisplay);
            assertTrue(display != EGL10.EGL_NO_DISPLAY, "no ANGLE display: 0x" + Integer.toHexString(EGL10.eglGetError()));
            IntBuffer major = stack.ints(0);
            IntBuffer minor = stack.ints(0);
            assertTrue(EGL10.eglInitialize(display, major, minor),
                    "eglInitialize: 0x" + Integer.toHexString(EGL10.eglGetError()));
            EGL.createDisplayCapabilities(display, major.get(0), minor.get(0));

            IntBuffer wanted = stack.ints(
                    EGL10.EGL_SURFACE_TYPE, EGL10.EGL_PBUFFER_BIT,
                    org.lwjgl.egl.EGL12.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                    EGL10.EGL_RED_SIZE, 8, EGL10.EGL_GREEN_SIZE, 8, EGL10.EGL_BLUE_SIZE, 8,
                    EGL10.EGL_ALPHA_SIZE, 8,
                    EGL10.EGL_NONE);
            PointerBuffer configs = stack.mallocPointer(1);
            IntBuffer count = stack.ints(0);
            assertTrue(EGL10.eglChooseConfig(display, wanted, configs, count) && count.get(0) > 0,
                    "no ES 3.0 pbuffer config");
            surface = EGL10.eglCreatePbufferSurface(display, configs.get(0),
                    stack.ints(EGL10.EGL_WIDTH, 16, EGL10.EGL_HEIGHT, 16, EGL10.EGL_NONE));
            assertTrue(surface != EGL10.EGL_NO_SURFACE, "pbuffer: 0x" + Integer.toHexString(EGL10.eglGetError()));
            context = EGL10.eglCreateContext(display, configs.get(0), EGL10.EGL_NO_CONTEXT,
                    stack.ints(EGL_CONTEXT_MAJOR_VERSION, 3, EGL10.EGL_NONE));
            assertTrue(context != EGL10.EGL_NO_CONTEXT, "context: 0x" + Integer.toHexString(EGL10.eglGetError()));
            assertTrue(EGL10.eglMakeCurrent(display, surface, surface, context), "make current");
        }
        capabilities = GLES.createCapabilities();
        System.out.println("ANGLE " + GLES30.glGetString(GLES30.GL_VERSION) + " on " + GLES30.glGetString(GLES30.GL_RENDERER));
    }

    @AfterAll
    static void close() {
        if (display != 0) {
            EGL10.eglMakeCurrent(display, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_CONTEXT);
            EGL10.eglDestroyContext(display, context);
            EGL10.eglDestroySurface(display, surface);
            EGL10.eglTerminate(display);
        }
    }

    @Test
    void theContextIsOpenGlEsThreeOnThePlatformsBackend() {
        assertTrue(GLES30.glGetString(GLES30.GL_VERSION).startsWith("OpenGL ES 3."), GLES30.glGetString(GLES30.GL_VERSION));
        String renderer = GLES30.glGetString(GLES30.GL_RENDERER);
        assertTrue(renderer.contains(macOs() ? "Metal" : "Direct3D11"), renderer);
    }

    @Test
    void theExtensionsTheToolkitsGatesNeedArePresent() {
        assertTrue(capabilities.GL_EXT_color_buffer_float, "EXT_color_buffer_float (the 3D target)");
        assertTrue(capabilities.GL_EXT_texture_norm16, "EXT_texture_norm16 (10-bit video planes)");
        assertTrue(capabilities.GL_EXT_disjoint_timer_query, "EXT_disjoint_timer_query (GPU timings)");
    }

    @Test
    void aClearIsReadBack() {
        GLES30.glViewport(0, 0, 16, 16);
        GLES30.glClearColor(1f, 0.5f, 0f, 1f);
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT);
        ByteBuffer pixel = MemoryUtil.memAlloc(4);
        try {
            GLES30.glReadPixels(4, 4, 1, 1, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, pixel);
            assertEquals(255, pixel.get(0) & 0xFF);
            assertEquals(128, pixel.get(1) & 0xFF, 1);
            assertEquals(0, pixel.get(2) & 0xFF);
        } finally {
            MemoryUtil.memFree(pixel);
        }
        assertEquals(GLES30.GL_NO_ERROR, GLES30.glGetError());
    }

    @Test
    void macOsOffersTheIoSurfaceBindingZeroCopyVideoNeeds() {
        Assumptions.assumeTrue(macOs(), "IOSurfaces are macOS's");
        assertTrue(EGL10.eglQueryString(display, EGL10.EGL_EXTENSIONS).contains("EGL_ANGLE_iosurface_client_buffer"),
                "EGL_ANGLE_iosurface_client_buffer");
    }
}
