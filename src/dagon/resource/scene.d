/*
Copyright (c) 2017-2018 Timur Gafarov

Boost Software License - Version 1.0 - August 17th, 2003
Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dagon.resource.scene;

import std.stdio;
import std.math;
import std.algorithm;
import std.traits;
import std.conv;
import std.path;

import dlib.core.memory;

import dlib.container.array;
import dlib.container.dict;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;
import dlib.math.quaternion;
import dlib.image.color;
import dlib.image.image;
import dlib.image.unmanaged;
import dlib.image.io.png;

import dagon.core.libs;
import dagon.core.ownership;
import dagon.core.event;
import dagon.core.application;

import dagon.resource.asset;
import dagon.resource.textasset;
import dagon.resource.textureasset;
import dagon.resource.imageasset;
import dagon.resource.fontasset;
import dagon.resource.obj;
import dagon.resource.iqm;
import dagon.resource.packageasset;
import dagon.resource.props;
import dagon.resource.config;

import dagon.graphics.environment;
import dagon.graphics.rc;
import dagon.graphics.view;
import dagon.graphics.shapes;
import dagon.graphics.light;
import dagon.graphics.shadow;
import dagon.graphics.texture;
import dagon.graphics.particles;
import dagon.graphics.framebuffer;
import dagon.graphics.renderer;

import dagon.graphics.material;

import dagon.graphics.shader;
import dagon.graphics.shaders.standard;
import dagon.graphics.shaders.sky;
import dagon.graphics.shaders.particle;
import dagon.graphics.shaders.hud;

import dagon.logics.entity;

class BaseScene: EventListener
{
    SceneManager sceneManager;
    AssetManager assetManager;
    bool canRun = false;
    bool releaseAtNextStep = false;
    bool needToLoad = true;

    this(SceneManager smngr)
    {
        super(smngr.eventManager, null);
        sceneManager = smngr;
        assetManager = New!AssetManager(eventManager);
    }

    ~this()
    {
        release();
        Delete(assetManager);
    }

    Configuration config() @property
    {
        return sceneManager.application.config;
    }

    // Set preload to true if you want to load the asset immediately
    // before actual loading (e.g., to render a loading screen)
    Asset addAsset(Asset asset, string filename, bool preload = false)
    {
        if (preload)
            assetManager.preloadAsset(asset, filename);
        else
            assetManager.addAsset(asset, filename);
        return asset;
    }

    void onAssetsRequest()
    {
        // Add your assets here
    }

    void onLoading(float percentage)
    {
        // Render your loading screen here
    }

    void onAllocate()
    {
        // Allocate your objects here
    }

    void onRelease()
    {
        // Release your objects here
    }

    void onStart()
    {
        // Do your (re)initialization here
    }

    void onEnd()
    {
        // Do your finalization here
    }

    void onUpdate(double dt)
    {
        // Do your animation and logics here
    }

    void onRender()
    {
        // Do your rendering here
    }

    void exitApplication()
    {
        generateUserEvent(DagonEvent.Exit);
    }

    void load()
    {
        if (needToLoad)
        {
            onAssetsRequest();
            float p = assetManager.nextLoadingPercentage;

            assetManager.loadThreadSafePart();

            while(assetManager.isLoading)
            {
                sceneManager.application.beginRender();
                onLoading(p);
                sceneManager.application.endRender();
                p = assetManager.nextLoadingPercentage;
            }

            bool loaded = assetManager.loadThreadUnsafePart();

            if (loaded)
            {
                onAllocate();
                canRun = true;
                needToLoad = false;
            }
            else
            {
                writeln("Exiting due to error while loading assets");
                canRun = false;
                eventManager.running = false;
            }
        }
        else
        {
            canRun = true;
        }
    }

    void release()
    {
        onRelease();
        clearOwnedObjects();
        assetManager.releaseAssets();
        needToLoad = true;
        canRun = false;
    }

    void start()
    {
        if (canRun)
            onStart();
    }

    void end()
    {
        if (canRun)
            onEnd();
    }

    void update(double dt)
    {
        if (canRun)
        {
            processEvents();
            assetManager.updateMonitor(dt);
            onUpdate(dt);
        }

        if (releaseAtNextStep)
        {
            end();
            release();

            releaseAtNextStep = false;
            canRun = false;
        }
    }

    void render()
    {
        if (canRun)
            onRender();
    }
}

class SceneManager: Owner
{
    SceneApplication application;
    Dict!(BaseScene, string) scenesByName;
    EventManager eventManager;
    BaseScene currentScene;

    this(EventManager emngr, SceneApplication app)
    {
        super(app);
        application = app;
        eventManager = emngr;
        scenesByName = New!(Dict!(BaseScene, string));
    }

    ~this()
    {
        foreach(i, s; scenesByName)
        {
            Delete(s);
        }
        Delete(scenesByName);
    }

    BaseScene addScene(BaseScene scene, string name)
    {
        scenesByName[name] = scene;
        return scene;
    }

    void removeScene(string name)
    {
        Delete(scenesByName[name]);
        scenesByName.remove(name);
    }

    void goToScene(string name, bool releaseCurrent = true)
    {
        if (currentScene && releaseCurrent)
        {
            currentScene.releaseAtNextStep = true;
        }

        BaseScene scene = scenesByName[name];

        writefln("Loading scene \"%s\"", name);

        scene.load();
        currentScene = scene;
        currentScene.start();

        writefln("Running...", name);
    }

    void update(double dt)
    {
        if (currentScene)
        {
            currentScene.update(dt);
        }
    }

    void render()
    {
        if (currentScene)
        {
            currentScene.render();
        }
    }
}

class SceneApplication: Application
{
    SceneManager sceneManager;
    UnmanagedImageFactory imageFactory;
    SuperImage screenshotBuffer1;
    SuperImage screenshotBuffer2;
    Configuration config;

    this(uint w, uint h, bool fullscreen, string windowTitle, string[] args)
    {
        super(w, h, fullscreen, windowTitle, args);

        config = New!Configuration(this);
        config.fromFile("settings.conf");
        config.props.set(DPropType.Number, "windowWidth", w.to!string);
        config.props.set(DPropType.Number, "windowHeight", h.to!string);
        config.props.set(DPropType.Number, "fullscreen", (cast(uint)fullscreen).to!string);

        sceneManager = New!SceneManager(eventManager, this);

        imageFactory = New!UnmanagedImageFactory();
        screenshotBuffer1 = imageFactory.createImage(eventManager.windowWidth, eventManager.windowHeight, 3, 8);
        screenshotBuffer2 = imageFactory.createImage(eventManager.windowWidth, eventManager.windowHeight, 3, 8);
    }

    this(string windowTitle, string[] args)
    {
        config = New!Configuration(this);
        if (!config.fromFile("settings.conf"))
            writeln("Warning: no \"settings.conf\" found, using default configuration");

        super(
            config.props.windowWidth.toUInt,
            config.props.windowHeight.toUInt,
            config.props.fullscreen.toBool,
            windowTitle,
            args);

        sceneManager = New!SceneManager(eventManager, this);

        imageFactory = New!UnmanagedImageFactory();
        screenshotBuffer1 = imageFactory.createImage(eventManager.windowWidth, eventManager.windowHeight, 3, 8);
        screenshotBuffer2 = imageFactory.createImage(eventManager.windowWidth, eventManager.windowHeight, 3, 8);
    }

    ~this()
    {
        Delete(imageFactory);
        Delete(screenshotBuffer1);
        Delete(screenshotBuffer2);
    }

    override void onUpdate(double dt)
    {
        sceneManager.update(dt);
    }

    override void onRender()
    {
        sceneManager.render();
    }

    void saveScreenshot(string filename)
    {
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glReadPixels(0, 0, eventManager.windowWidth, eventManager.windowHeight, GL_RGB, GL_UNSIGNED_BYTE, screenshotBuffer1.data.ptr);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4);

        foreach(y; 0..screenshotBuffer1.height)
        foreach(x; 0..screenshotBuffer1.width)
        {
            screenshotBuffer2[x, y] = screenshotBuffer1[x, screenshotBuffer1.height - y];
        }

        screenshotBuffer2.savePNG(filename);
    }
}

class Scene: BaseScene
{
    Renderer renderer;
    Environment environment;
    LightManager lightManager;
    ParticleSystem particleSystem;

	StandardShader standardShader;
    SkyShader skyShader;
    ParticleShader particleShader;
    Material defaultMaterial3D;
    View view;

    DynamicArray!Entity _entities3D;
    DynamicArray!Entity _entities2D;
    Entities3D entities3Dflat;
    Entities2D entities2Dflat;

    ShapeQuad loadingProgressBar;
    Entity eLoadingProgressBar;
    HUDShader hudShader;
    Material mLoadingProgressBar;

    double timer = 0.0;
    double fixedTimeStep = 1.0 / 60.0;
    uint maxUpdatesPerFrame = 5;

    this(SceneManager smngr)
    {
        super(smngr);

        loadingProgressBar = New!ShapeQuad(assetManager);
        eLoadingProgressBar = New!Entity(eventManager, assetManager);
        eLoadingProgressBar.drawable = loadingProgressBar;
        hudShader = New!HUDShader(assetManager);
        mLoadingProgressBar = createMaterial(hudShader);
        mLoadingProgressBar.diffuse = Color4f(1, 1, 1, 1);
        eLoadingProgressBar.material = mLoadingProgressBar;
    }

    override void onAllocate()
    {
        environment = New!Environment(assetManager);
        lightManager = New!LightManager(assetManager);

        entities3Dflat = New!Entities3D(this, assetManager);
        entities2Dflat = New!Entities2D(this, assetManager);

        renderer = New!Renderer(this, assetManager);

        standardShader = New!StandardShader(assetManager);
        //standardShader.shadowMap = renderer.shadowMap;
        skyShader = New!SkyShader(assetManager);
        particleShader = New!ParticleShader(renderer.gbuffer, assetManager);

        particleSystem = New!ParticleSystem(assetManager);

        defaultMaterial3D = createMaterial();

        timer = 0.0;
    }

    void sortEntities(ref DynamicArray!Entity entities)
    {
        size_t j = 0;
        Entity tmp;

        auto edata = entities.data;

        foreach(i, v; edata)
        {
            j = i;
            size_t k = i;

            while (k < edata.length)
            {
                float b1 = edata[j].layer;
                float b2 = edata[k].layer;

                if (b2 < b1)
                    j = k;

                k++;
            }

            tmp = edata[i];
            edata[i] = edata[j];
            edata[j] = tmp;

            sortEntities(v.children);
        }
    }

    auto asset(string filename, Args...)(Args args)
    {
        enum string e = filename.extension;
        static if (e == ".txt" || e == ".TXT")
            return addTextAsset(filename);
        else static if (e == ".png" || e == ".PNG" ||
                        e == ".jpg" || e == ".JPG" ||
                        e == ".hdr" || e == ".HDR" ||
                        e == ".bmp" || e == ".BMP" ||
                        e == ".tga" || e == ".TGA")
            return addTextureAsset(filename);
        else static if (e == ".ttf" || e == ".TTF")
            return addFontAsset(filename, args[0]);
        else static if (e == ".obj" || e == ".OBJ")
            return addOBJAsset(filename);
        else static if (e == ".iqm" || e == ".IQM")
            return addIQMAsset(filename);
        else static if (e == ".asset" || e == ".ASSET")
            return addPackageAsset(filename);
        else
            static assert(0, "Failed to detect asset type at compile time, call addAsset explicitly");
    }

    TextAsset addTextAsset(string filename, bool preload = false)
    {
        TextAsset text;
        if (assetManager.assetExists(filename))
            text = cast(TextAsset)assetManager.getAsset(filename);
        else
        {
            text = New!TextAsset(assetManager);
            addAsset(text, filename, preload);
        }
        return text;
    }

    TextureAsset addTextureAsset(string filename, bool preload = false)
    {
        TextureAsset tex;
        if (assetManager.assetExists(filename))
            tex = cast(TextureAsset)assetManager.getAsset(filename);
        else
        {
            tex = New!TextureAsset(assetManager.imageFactory, assetManager.hdrImageFactory, assetManager);
            addAsset(tex, filename, preload);
        }
        return tex;
    }

    ImageAsset addImageAsset(string filename, bool preload = false)
    {
        ImageAsset img;
        if (assetManager.assetExists(filename))
            img = cast(ImageAsset)assetManager.getAsset(filename);
        else
        {
            img = New!ImageAsset(assetManager.imageFactory, assetManager.hdrImageFactory, assetManager);
            addAsset(img, filename, preload);
        }
        return img;
    }

    FontAsset addFontAsset(string filename, uint height, bool preload = false)
    {
        FontAsset font;
        if (assetManager.assetExists(filename))
            font = cast(FontAsset)assetManager.getAsset(filename);
        else
        {
            font = New!FontAsset(height, assetManager);
            addAsset(font, filename, preload);
        }
        return font;
    }

    OBJAsset addOBJAsset(string filename, bool preload = false)
    {
        OBJAsset obj;
        if (assetManager.assetExists(filename))
            obj = cast(OBJAsset)assetManager.getAsset(filename);
        else
        {
            obj = New!OBJAsset(assetManager);
            addAsset(obj, filename, preload);
        }
        return obj;
    }

    IQMAsset addIQMAsset(string filename, bool preload = false)
    {
        IQMAsset iqm;
        if (assetManager.assetExists(filename))
            iqm = cast(IQMAsset)assetManager.getAsset(filename);
        else
        {
            iqm = New!IQMAsset(assetManager);
            addAsset(iqm, filename, preload);
        }
        return iqm;
    }

    PackageAsset addPackageAsset(string filename, bool preload = false)
    {
        PackageAsset pa;
        if (assetManager.assetExists(filename))
            pa = cast(PackageAsset)assetManager.getAsset(filename);
        else
        {
            pa = New!PackageAsset(this, assetManager);
            addAsset(pa, filename, preload);
        }
        return pa;
    }

    Entity createEntity2D(Entity parent = null)
    {
        Entity e;
        if (parent)
            e = New!Entity(parent);
        else
        {
            e = New!Entity(eventManager, assetManager);
            _entities2D.append(e);

            sortEntities(_entities2D);
        }

        return e;
    }

    Entity createEntity3D(Entity parent = null)
    {
        Entity e;
        if (parent)
            e = New!Entity(parent);
        else
        {
            e = New!Entity(eventManager, assetManager);
            _entities3D.append(e);

            sortEntities(_entities3D);
        }

        e.material = defaultMaterial3D;

        return e;
    }

    Entity addEntity3D(Entity e)
    {
        _entities3D.append(e);
        sortEntities(_entities3D);
        return e;
    }

    Entity createSky(Material mat = null)
    {
        Material matSky;
        if (mat is null)
        {
            matSky = New!Material(skyShader, assetManager);
            matSky.depthWrite = false;
        }
        else
        {
            matSky = mat;
        }

        auto eSky = createEntity3D();
        eSky.layer = 0;
        eSky.attach = Attach.Camera;
        eSky.castShadow = false;
        eSky.material = matSky;
        // TODO: use box instead of sphere
        eSky.drawable = New!ShapeSphere(1.0f, 16, 8, true, assetManager);
        eSky.scaling = Vector3f(100.0f, 100.0f, 100.0f);
        return eSky;
    }

    Material createMaterial(Shader shader)
    {
        auto m = New!Material(shader, assetManager);
        if (shader !is standardShader)
            m.customShader = true;
        return m;
    }

    Material createMaterial()
    {
        return createMaterial(standardShader);
    }

    Material createParticleMaterial(Shader shader = null)
    {
        if (shader is null)
            shader = particleShader;
        return New!Material(shader, assetManager);
    }

    deprecated("use Scene.createLightSphere instead") LightSource createLight(Vector3f position, Color4f color, float energy, float volumeRadius, float areaRadius = 0.0f)
    {
        return createLightSphere(position, color, energy, volumeRadius, areaRadius);
    }

    LightSource createLightSphere(Vector3f position, Color4f color, float energy, float volumeRadius, float areaRadius)
    {
        auto light = lightManager.addPointLight(position, color, energy, volumeRadius, areaRadius);
        light.type = LightType.AreaSphere;
        return light;
    }

    LightSource createLightTube(Vector3f position, Color4f color, float energy, float volumeRadius, float tubeRadius, Quaternionf rotation, float tubeLength)
    {
        auto light = lightManager.addPointLight(position, color, energy, volumeRadius, tubeRadius);
        light.type = LightType.AreaTube;
        light.rotation = rotation;
        light.tubeLength = tubeLength;
        return light;
    }

    LightSource createLightSun(Quaternionf rotation, Color4f color, float energy)
    {
        return lightManager.addSunLight(rotation, color, energy);
    }

    override void onRelease()
    {
        _entities3D.free();
        _entities2D.free();
    }

    // TODO: move to separate class
    override void onLoading(float percentage)
    {
        RenderingContext rc2d;
        rc2d.init(eventManager, environment);
        rc2d.projectionMatrix = orthoMatrix(0.0f, eventManager.windowWidth, 0.0f, eventManager.windowHeight, 0.0f, 100.0f);

        glEnable(GL_SCISSOR_TEST);
        glScissor(0, 0, eventManager.windowWidth, eventManager.windowHeight);
        glViewport(0, 0, eventManager.windowWidth, eventManager.windowHeight);
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        float maxWidth = eventManager.windowWidth * 0.33f;
        float x = (eventManager.windowWidth - maxWidth) * 0.5f;
        float y = eventManager.windowHeight * 0.5f - 10;
        float w = percentage * maxWidth;

        glDisable(GL_DEPTH_TEST);
        mLoadingProgressBar.diffuse = Color4f(0.1, 0.1, 0.1, 1);
        eLoadingProgressBar.position = Vector3f(x, y, 0);
        eLoadingProgressBar.scaling = Vector3f(maxWidth, 10, 1);
        eLoadingProgressBar.update(1.0/60.0);
        eLoadingProgressBar.render(&rc2d);

        mLoadingProgressBar.diffuse = Color4f(1, 1, 1, 1);
        eLoadingProgressBar.scaling = Vector3f(w, 10, 1);
        eLoadingProgressBar.update(1.0/60.0);
        eLoadingProgressBar.render(&rc2d);
    }

    override void onStart()
    {
    }

    void onLogicsUpdate(double dt)
    {
    }

    void fixedStepUpdate(bool logicsUpdate = true)
    {
        if (view)
        {
            view.update(fixedTimeStep);
            view.prepareRC(&renderer.rc3d);
        }

        renderer.rc3d.time += fixedTimeStep;
        renderer.rc2d.time += fixedTimeStep;

        foreach(e; _entities3D)
            e.update(fixedTimeStep);

        foreach(e; _entities2D)
            e.update(fixedTimeStep);

        particleSystem.update(fixedTimeStep);

        if (logicsUpdate)
            onLogicsUpdate(fixedTimeStep);

        environment.update(fixedTimeStep);

        if (view)
            lightManager.updateShadows(view, &renderer.rc3d, fixedTimeStep);
    }

    override void onUpdate(double dt)
    {
        foreach(e; _entities3D)
            e.processEvents();

        foreach(e; _entities2D)
            e.processEvents();

        int updateCount = 0;

        timer += dt;
        while (timer >= fixedTimeStep)
        {
            if (updateCount < maxUpdatesPerFrame)
                fixedStepUpdate();

            timer -= fixedTimeStep;
            updateCount++;
        }
    }

    override void onRender()
    {
        renderer.render();
    }
}

alias Scene BaseScene3D;


interface EntityGroup
{
    int opApply(scope int delegate(Entity) dg);
}

class Entities3D: Owner, EntityGroup
{
    Scene scene;

    this(Scene scene, Owner o)
    {
        super(o);
        this.scene = scene;
    }

    int opApply(scope int delegate(Entity) dg)
    {
        int res = 0;
        for(size_t i = 0; i < scene._entities3D.data.length; i++)
        {
            auto e = scene._entities3D.data[i];

            res = traverseEntitiesTree(e, dg);
            if (res)
                break;
        }
        return res;
    }

    protected int traverseEntitiesTree(Entity e, scope int delegate(Entity) dg)
    {
        int res = 0;
        for(size_t i = 0; i < e.children.data.length; i++)
        {
            auto c = e.children.data[i];

            res = traverseEntitiesTree(c, dg);
            if (res)
                break;
        }

        if (res == 0)
            res = dg(e);

        return res;
    }
}

class Entities2D: Owner, EntityGroup
{
    Scene scene;

    this(Scene scene, Owner o)
    {
        super(o);
        this.scene = scene;
    }

    int opApply(scope int delegate(Entity) dg)
    {
        int res = 0;
        for(size_t i = 0; i < scene._entities2D.data.length; i++)
        {
            auto e = scene._entities2D.data[i];

            res = traverseEntitiesTree(e, dg);
            if (res)
                break;
        }
        return res;
    }

    protected int traverseEntitiesTree(Entity e, scope int delegate(Entity) dg)
    {
        int res = 0;
        for(size_t i = 0; i < e.children.data.length; i++)
        {
            auto c = e.children.data[i];

            res = traverseEntitiesTree(c, dg);
            if (res)
                break;
        }

        if (res == 0)
            res = dg(e);

        return res;
    }
}
