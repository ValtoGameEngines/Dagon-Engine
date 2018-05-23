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

module dagon.graphics.materials.standard;

import std.stdio;
import std.math;

import dlib.core.memory;
import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;
import dlib.math.interpolation;
import dlib.image.color;

import derelict.opengl;

import dagon.core.ownership;
import dagon.graphics.rc;
import dagon.graphics.shadow;
import dagon.graphics.clustered;
import dagon.graphics.texture;
import dagon.graphics.material;
import dagon.graphics.materials.generic;

class StandardBackend: GLSLMaterialBackend
{
    private string vsText = 
    q{
        #version 330 core
        
        uniform mat4 modelViewMatrix;
        uniform mat4 normalMatrix;
        uniform mat4 projectionMatrix;
        
        uniform mat4 invViewMatrix;
        
        uniform mat4 prevModelViewProjMatrix;
        uniform mat4 blurModelViewProjMatrix;
        
        uniform mat4 shadowMatrix1;
        uniform mat4 shadowMatrix2;
        uniform mat4 shadowMatrix3;
        
        layout (location = 0) in vec3 va_Vertex;
        layout (location = 1) in vec3 va_Normal;
        layout (location = 2) in vec2 va_Texcoord;
        
        out vec4 position;
        out vec4 blurPosition;
        out vec4 prevPosition;
        
        out vec3 eyePosition;
        out vec3 eyeNormal;
        out vec2 texCoord;
        
        out vec3 worldPosition;
        out vec3 worldView;
        
        out vec4 shadowCoord1;
        out vec4 shadowCoord2;
        out vec4 shadowCoord3;
        
        const float eyeSpaceNormalShift = 0.05;
        
        void main()
        {
            texCoord = va_Texcoord;
            eyeNormal = (normalMatrix * vec4(va_Normal, 0.0)).xyz;
            vec4 pos = modelViewMatrix * vec4(va_Vertex, 1.0);
            eyePosition = pos.xyz;
            
            position = projectionMatrix * pos;
            blurPosition = blurModelViewProjMatrix * vec4(va_Vertex, 1.0);
            prevPosition = prevModelViewProjMatrix * vec4(va_Vertex, 1.0);
            
            worldPosition = (invViewMatrix * pos).xyz;

            vec3 worldCamPos = (invViewMatrix[3]).xyz;
            worldView = worldPosition - worldCamPos;
            
            vec4 posShifted = pos + vec4(eyeNormal * eyeSpaceNormalShift, 0.0);
            shadowCoord1 = shadowMatrix1 * posShifted;
            shadowCoord2 = shadowMatrix2 * posShifted;
            shadowCoord3 = shadowMatrix3 * posShifted;
            
            gl_Position = position;
        }
    };

    private string fsText =
    q{
        #version 330 core
        
        #define EPSILON 0.000001
        #define PI 3.14159265359
        const float PI2 = PI * 2.0;
        
        uniform mat4 viewMatrix;
        uniform mat4 invViewMatrix;
        
        uniform mat4 shadowMatrix1;
        uniform mat4 shadowMatrix2;
        
        uniform sampler2D diffuseTexture;
        uniform sampler2D normalTexture;
        uniform sampler2D emissionTexture;

        uniform sampler2D pbrTexture;
        
        uniform int parallaxMethod;
        uniform float parallaxScale;
        uniform float parallaxBias;

        uniform float emissionEnergy;
        
        uniform sampler2DArrayShadow shadowTextureArray;
        uniform float shadowTextureSize;
        uniform bool useShadows;
        uniform vec4 shadowColor;
        uniform float shadowBrightness;
        uniform bool useHeightCorrectedShadows;
        
        uniform sampler2D environmentMap;
        uniform bool useEnvironmentMap;
        
        uniform vec4 environmentColor;
        uniform vec3 sunDirection;
        uniform vec3 sunColor;
        uniform float sunEnergy;
        uniform vec4 fogColor;
        uniform float fogStart;
        uniform float fogEnd;
        
        uniform vec3 skyZenithColor;
        uniform vec3 skyHorizonColor;
        
        uniform float invLightDomainSize;
        uniform usampler2D lightClusterTexture;
        uniform usampler1D lightIndexTexture;
        uniform sampler2D lightsTexture;
        
        uniform float blurMask;
        
        uniform bool shaded;
        uniform float transparency;
        uniform bool usePCF;
        //const bool shaded = true;
        //const float transparency = 1.0;
        //const bool usePCF = true;
        
        in vec3 eyePosition;
        
        in vec4 position;
        in vec4 blurPosition;
        in vec4 prevPosition;
        
        in vec3 eyeNormal;
        in vec2 texCoord;
        
        in vec3 worldPosition;
        in vec3 worldView;
        
        in vec4 shadowCoord1;
        in vec4 shadowCoord2;
        in vec4 shadowCoord3;

        layout(location = 0) out vec4 frag_color;
        layout(location = 1) out vec4 frag_velocity;
        layout(location = 2) out vec4 frag_luma;
        layout(location = 3) out vec4 frag_position; // TODO: gbuffer prepass to do SSAO and SSLR
        layout(location = 4) out vec4 frag_normal;   // TODO: gbuffer prepass to do SSAO and SSLR
        
        mat3 cotangentFrame(in vec3 N, in vec3 p, in vec2 uv)
        {
            vec3 dp1 = dFdx(p);
            vec3 dp2 = dFdy(p);
            vec2 duv1 = dFdx(uv);
            vec2 duv2 = dFdy(uv);
            vec3 dp2perp = cross(dp2, N);
            vec3 dp1perp = cross(N, dp1);
            vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
            vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;
            float invmax = inversesqrt(max(dot(T, T), dot(B, B)));
            return mat3(T * invmax, B * invmax, N);
        }
        
        vec2 parallaxMapping(in vec3 V, in vec2 T, in float scale, out float h)
        {
            float height = texture(normalTexture, T).a;
            h = height;
            height = height * parallaxScale + parallaxBias;
            return T + (height * V.xy);
        }
        
        // Based on code written by Igor Dykhta (Sun and Black Cat)
        // http://sunandblackcat.com/tipFullView.php?topicid=28
        vec2 parallaxOcclusionMapping(in vec3 V, in vec2 T, in float scale, out float h)
        {
            const float minLayers = 10;
            const float maxLayers = 15;
            float numLayers = mix(maxLayers, minLayers, abs(dot(vec3(0, 0, 1), V)));

            float layerHeight = 1.0 / numLayers;
            float curLayerHeight = 0;
            vec2 dtex = scale * V.xy / V.z / numLayers;

            vec2 currentTextureCoords = T;
            float heightFromTexture = texture(normalTexture, currentTextureCoords).a;
            
            h = heightFromTexture;

            while(heightFromTexture > curLayerHeight)
            {
                curLayerHeight += layerHeight;
                currentTextureCoords += dtex;
                heightFromTexture = texture(normalTexture, currentTextureCoords).a;
            }

            vec2 prevTCoords = currentTextureCoords - dtex;

            float nextH = heightFromTexture - curLayerHeight;
            float prevH = texture(normalTexture, prevTCoords).a - curLayerHeight + layerHeight;
            float weight = nextH / (nextH - prevH);
            return prevTCoords * weight + currentTextureCoords * (1.0-weight);
        }
        
        float shadowLookup(in sampler2DArrayShadow depths, in float layer, in vec4 coord, in vec2 offset)
        {
            float texelSize = 1.0 / shadowTextureSize;
            vec2 v = offset * texelSize * coord.w;
            vec4 c = (coord + vec4(v.x, v.y, 0.0, 0.0)) / coord.w;
            c.w = c.z;
            c.z = layer;
            float s = texture(depths, c);
            return s;
        }
        
        float shadow(in sampler2DArrayShadow depths, in float layer, in vec4 coord, in float yshift)
        {
            return shadowLookup(depths, layer, coord, vec2(0.0, yshift));
        }
        
        float shadowPCF(in sampler2DArrayShadow depths, in float layer, in vec4 coord, in float radius, in float yshift)
        {
            float s = 0.0;
            float x, y;
	        for (y = -radius ; y < radius ; y += 1.0)
	        for (x = -radius ; x < radius ; x += 1.0)
            {
	            s += shadowLookup(depths, layer, coord, vec2(x, y + yshift));
            }
	        s /= radius * radius * 4.0;
            return s;
        }
        
        float weight(in vec4 tc, in float coef)
        {
            vec2 proj = vec2(tc.x / tc.w, tc.y / tc.w);
            proj = (1.0 - abs(proj * 2.0 - 1.0)) * coef;
            proj = clamp(proj, 0.0, 1.0);
            return min(proj.x, proj.y);
        }
        
        void sphericalAreaLightContrib(
            in vec3 P, in vec3 N, in vec3 E, in vec3 R,
            in vec3 lPos, in float lRadius,
            in float shininess,
            out float diff, out float spec)
        {
            vec3 positionToLightSource = lPos - P;
	        vec3 centerToRay = dot(positionToLightSource, R) * R - positionToLightSource;
	        vec3 closestPoint = positionToLightSource + centerToRay * clamp(lRadius / length(centerToRay), 0.0, 1.0);	
	        vec3 L = normalize(closestPoint);
            float NH = dot(N, normalize(L + E));
            spec = pow(max(NH, 0.0), shininess);
            vec3 directionToLight = normalize(positionToLightSource);
            diff = clamp(dot(N, directionToLight), 0.0, 1.0);
        }
        
        vec3 fresnel(float cosTheta, vec3 f0)
        {
            return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);
        }

        vec3 fresnelRoughness(float cosTheta, vec3 f0, float roughness)
        {
            return f0 + (max(vec3(1.0 - roughness), f0) - f0) * pow(1.0 - cosTheta, 5.0);
        }

        float distributionGGX(vec3 N, vec3 H, float roughness)
        {
            float a = roughness * roughness;
            float a2 = a * a;
            float NdotH = max(dot(N, H), 0.0);
            float NdotH2 = NdotH * NdotH;
            float num = a2;
            float denom = max(NdotH2 * (a2 - 1.0) + 1.0, 0.001);
            denom = PI * denom * denom;
            return num / denom;
        }

        float geometrySchlickGGX(float NdotV, float roughness)
        {
            float r = (roughness + 1.0);
            float k = (r*r) / 8.0;
            float num = NdotV;
            float denom = NdotV * (1.0 - k) + k;
            return num / denom;
        }

        float geometrySmith(vec3 N, vec3 V, vec3 L, float roughness)
        {
            float NdotV = max(dot(N, V), 0.0);
            float NdotL = max(dot(N, L), 0.0);
            float ggx2  = geometrySchlickGGX(NdotV, roughness);
            float ggx1  = geometrySchlickGGX(NdotL, roughness);
            return ggx1 * ggx2;
        }

        uniform vec3 groundColor;
        uniform float skyEnergy;
        uniform float groundEnergy;

        vec3 sky(vec3 wN, vec3 wSun, float roughness)
        {            
            float p1 = clamp(roughness, 0.5, 1.0);
            float p2 = clamp(roughness, 0.4, 1.0);
        
            float horizonOrZenith = pow(clamp(dot(wN, vec3(0, 1, 0)), 0.0, 1.0), p1);
            float groundOrSky = pow(clamp(dot(wN, vec3(0, -1, 0)), 0.0, 1.0), p2);

            vec3 env = mix(mix(skyHorizonColor * skyEnergy, groundColor * groundEnergy, groundOrSky), skyZenithColor * skyEnergy, horizonOrZenith);
            
            return env;
        }
        
        vec2 envMapEquirect(vec3 dir)
        {
            float phi = acos(dir.y);
            float theta = atan(dir.x, dir.z) + PI;
            return vec2(theta / PI2, phi / PI);
        }

        vec3 toLinear(vec3 v)
        {
            return pow(v, vec3(2.2));
        }
        
        float luminance(vec3 color)
        {
            return (
                color.x * 0.27 +
                color.y * 0.67 +
                color.z * 0.06
            );
        }
        
        void main()
        {     
            // Common vectors
            vec3 vN = normalize(eyeNormal);
            vec3 N = vN;
            vec3 E = normalize(-eyePosition);
            mat3 TBN = cotangentFrame(N, eyePosition, texCoord);
            vec3 tE = normalize(E * TBN);
            
            vec3 cameraPosition = invViewMatrix[3].xyz;
            float linearDepth = -eyePosition.z;
            
            vec2 posScreen = (blurPosition.xy / blurPosition.w) * 0.5 + 0.5;
            vec2 prevPosScreen = (prevPosition.xy / prevPosition.w) * 0.5 + 0.5;
            vec2 screenVelocity = posScreen - prevPosScreen;

            // Parallax mapping
            float height = 0.0;
            vec2 shiftedTexCoord = texCoord;
            if (parallaxMethod == 0)
                shiftedTexCoord = texCoord;
            else if (parallaxMethod == 1)
                shiftedTexCoord = parallaxMapping(tE, texCoord, parallaxScale, height);
            else if (parallaxMethod == 2)
                shiftedTexCoord = parallaxOcclusionMapping(tE, texCoord, parallaxScale, height);
            
            // Normal mapping
            vec3 tN = normalize(texture(normalTexture, shiftedTexCoord).rgb * 2.0 - 1.0);
            tN.y = -tN.y;
            N = normalize(TBN * tN);
             
            // Calculate shadow from 3 cascades           
            float s1, s2, s3;
            if (shaded && useShadows)
            {
                vec4 sc1 = useHeightCorrectedShadows? shadowMatrix1 * vec4(eyePosition + vN * height * 0.3, 1.0) : shadowCoord1;
                vec4 sc2 = useHeightCorrectedShadows? shadowMatrix2 * vec4(eyePosition + vN * height * 0.3, 1.0) : shadowCoord2;
            
                s1 = usePCF? shadowPCF(shadowTextureArray, 0.0, sc1, 2.0, 0.0) : 
                             shadow(shadowTextureArray, 0.0, sc1, 0.0);
                s2 = shadow(shadowTextureArray, 1.0, sc2, 0.0);
                s3 = shadow(shadowTextureArray, 2.0, shadowCoord3, 0.0);
                float w1 = weight(sc1, 8.0);
                float w2 = weight(sc2, 8.0);
                float w3 = weight(shadowCoord3, 8.0);
                s3 = mix(1.0, s3, w3); 
                s2 = mix(s3, s2, w2);
                s1 = mix(s2, s1, w1); // s1 stores resulting shadow value
            }
            else
            {
                s1 = 1.0f;
            }
            
            float roughness = texture(pbrTexture, shiftedTexCoord).r;
            float metallic = texture(pbrTexture, shiftedTexCoord).g;
            
            vec3 R = reflect(E, N);
            
            vec3 worldN = N * mat3(viewMatrix);
            vec3 worldR = reflect(normalize(worldView), worldN);
            vec3 worldSun = sunDirection * mat3(viewMatrix);
            
            // Diffuse texture
            vec4 diffuseColor = texture(diffuseTexture, shiftedTexCoord);
            vec3 albedo = toLinear(diffuseColor.rgb);
            
            vec3 emissionColor = toLinear(texture(emissionTexture, shiftedTexCoord).rgb);
            
            vec3 f0 = vec3(0.04); 
            f0 = mix(f0, albedo, metallic);
            
            vec3 Lo = vec3(0.0);
            
            // Sun light
            float sunDiffuselight = 1.0;
            // if (sunEnabled)
            if (shaded)
            {
                vec3 L = sunDirection;
                float NL = max(dot(N, L), 0.0); 
                vec3 H = normalize(E + L); 
                
                float NDF = distributionGGX(N, H, roughness);        
                float G = geometrySmith(N, E, L, roughness);
                vec3 F = fresnel(max(dot(H, E), 0.0), f0);
                
                vec3 kS = F;
                vec3 kD = vec3(1.0) - kS;
                kD *= 1.0 - metallic;

                vec3 numerator = NDF * G * F;
                float denominator = 4.0 * max(dot(N, E), 0.0) * NL;
                vec3 specular = numerator / max(denominator, 0.001);
                
                sunDiffuselight = NL;

                //shadow = mix(s1 * NL, 1.0, shadowBrightness);
                vec3 radiance = sunColor * sunEnergy * s1 * NL;
                Lo += (kD * albedo / PI + specular) * radiance;
            }
            
            // Fetch light cluster slice
            if (shaded)
            {
                vec2 clusterCoord = (worldPosition.xz - cameraPosition.xz) * invLightDomainSize + 0.5;
                uint clusterIndex = texture(lightClusterTexture, clusterCoord).r;
                uint offset = (clusterIndex << 16) >> 16;
                uint size = (clusterIndex >> 16);
                
                // Point/area lights
                for (uint i = 0u; i < size; i++)
                {
                    // Read light data
                    uint u = texelFetch(lightIndexTexture, int(offset + i), 0).r;
                    vec3 lightPos = texelFetch(lightsTexture, ivec2(u, 0), 0).xyz; 
                    vec3 lightColor = toLinear(texelFetch(lightsTexture, ivec2(u, 1), 0).xyz); 
                    vec3 lightProps = texelFetch(lightsTexture, ivec2(u, 2), 0).xyz;
                    float lightRadius = lightProps.x;
                    float lightAreaRadius = lightProps.y;
                    float lightEnergy = lightProps.z;
                    
                    vec3 lightPosEye = (viewMatrix * vec4(lightPos, 1.0)).xyz;
                    
                    vec3 positionToLightSource = lightPosEye - eyePosition;
                    float distanceToLight = length(positionToLightSource);
                    vec3 directionToLight = normalize(positionToLightSource);                
                    float attenuation = pow(clamp(1.0 - (distanceToLight / lightRadius), 0.0, 1.0), 2.0) * lightEnergy;
                    
                    vec3 Lpt = normalize(lightPosEye - eyePosition);

                    vec3 centerToRay = dot(positionToLightSource, R) * R - positionToLightSource;
                    vec3 closestPoint = positionToLightSource + centerToRay * clamp(lightAreaRadius / length(centerToRay), 0.0, 1.0);
                    vec3 L = normalize(closestPoint);  

                    float NL = max(dot(N, Lpt), 0.0); 
                    vec3 H = normalize(E + L);
                    
                    float NDF = distributionGGX(N, H, roughness);        
                    float G = geometrySmith(N, E, L, roughness);      
                    vec3 F = fresnel(max(dot(H, E), 0.0), f0);
                    
                    vec3 kS = F;
                    vec3 kD = vec3(1.0) - kS;
                    kD *= 1.0 - metallic;

                    vec3 numerator = NDF * G * F;
                    float denominator = 4.0 * max(dot(N, E), 0.0) * NL;
                    vec3 specular = numerator / max(denominator, 0.001);
                    
                    vec3 radiance = lightColor * attenuation;
                    
                    Lo += (kD * albedo / PI + specular) * radiance * NL;
                }
            }
            
            // Fog
            float fogFactor = clamp((fogEnd - linearDepth) / (fogEnd - fogStart), 0.0, 1.0);
            
            // Environment light
            if (shaded)
            {
                vec3 ambientDiffuse;
                vec3 ambientSpecular;
                if (useEnvironmentMap)
                {
                    ivec2 envMapSize = textureSize(environmentMap, 0);
                    float maxLod = log2(float(max(envMapSize.x, envMapSize.y)));
                    float diffLod = (maxLod - 1.0);
                    float specLod = (maxLod - 1.0) * roughness;
                    
                    ambientDiffuse = textureLod(environmentMap, envMapEquirect(worldN), diffLod).rgb;
                    ambientSpecular = textureLod(environmentMap, envMapEquirect(worldR), specLod).rgb;
                }
                else
                {
                    ambientDiffuse = sky(worldN, worldSun, roughness);
                    ambientSpecular = sky(worldR, worldSun, roughness);
                }
                
                float dayOrNight = float(worldSun.y < 0.0);
                
                float ambientBrightness = mix(s1 * sunDiffuselight, 1.0, mix(shadowBrightness, 1.0, dayOrNight));
                ambientDiffuse = ambientDiffuse * toLinear(shadowColor.rgb) * ambientBrightness;
                ambientSpecular = ambientSpecular * toLinear(shadowColor.rgb) * ambientBrightness;
                
                {
                    vec3 F = fresnelRoughness(max(dot(N, E), 0.0), f0, roughness);
                    vec3 kS = F;
                    vec3 kD = 1.0 - kS;
                    kD *= 1.0 - metallic;
                    vec3 diffuse = ambientDiffuse * albedo;
                    vec3 ambient = kD * diffuse + F * ambientSpecular;
                    Lo += ambient;
                }
            }
            
            vec3 emit = emissionColor + albedo * (1.0 - float(shaded));
            
            vec3 objColor = Lo + emit * emissionEnergy;
            
            vec3 fragColor = mix(fogColor.rgb, objColor, fogFactor);
            float fresnelAlpha = shaded? pow(1.0 - max(0.0, dot(N, E)), 5.0) : 0.0; 
            
            float alpha = mix(diffuseColor.a, 1.0f, fresnelAlpha) * transparency;
            
            frag_color = vec4(fragColor, alpha);
            frag_velocity = vec4(screenVelocity, 0.0, blurMask);
            frag_luma = vec4(luminance(fragColor));
            frag_position = vec4(eyePosition.x, eyePosition.y, eyePosition.z, 0.0);
            frag_normal = vec4(N, 0.0);
        }
    };
    
    override string vertexShaderSrc() {return vsText;}
    override string fragmentShaderSrc() {return fsText;}

    GLint viewMatrixLoc;
    GLint modelViewMatrixLoc;
    GLint projectionMatrixLoc;
    GLint normalMatrixLoc;
    GLint invViewMatrixLoc;
    
    GLint prevModelViewProjMatrixLoc;
    GLint blurModelViewProjMatrixLoc;
    
    GLint shadowMatrix1Loc;
    GLint shadowMatrix2Loc; 
    GLint shadowMatrix3Loc;
    GLint shadowTextureArrayLoc;
    GLint shadowTextureSizeLoc;
    GLint useShadowsLoc;
    GLint shadowColorLoc;
    GLint shadowBrightnessLoc;
    GLint useHeightCorrectedShadowsLoc;

    GLint pbrTextureLoc;
    
    GLint parallaxMethodLoc;
    GLint parallaxScaleLoc;
    GLint parallaxBiasLoc;
    
    GLint diffuseTextureLoc;
    GLint normalTextureLoc;
    GLint emissionTextureLoc;
    GLint emissionEnergyLoc;
    
    GLint environmentMapLoc;
    GLint useEnvironmentMapLoc;
    
    GLint environmentColorLoc;
    GLint sunDirectionLoc;
    GLint sunColorLoc;
    GLint sunEnergyLoc;
    GLint fogStartLoc;
    GLint fogEndLoc;
    GLint fogColorLoc;
    
    GLint skyZenithColorLoc;
    GLint skyHorizonColorLoc;
    GLint skyEnergyLoc;
    GLint groundColorLoc;
    GLint groundEnergyLoc;
    
    GLint invLightDomainSizeLoc;
    GLint clusterTextureLoc;
    GLint lightsTextureLoc;
    GLint indexTextureLoc;
    
    GLint blurMaskLoc;
    
    GLint shadedLoc;
    GLint transparencyLoc;
    GLint usePCFLoc;
    
    ClusteredLightManager lightManager;
    CascadedShadowMap shadowMap;
    Matrix4x4f defaultShadowMat;
    Vector3f defaultLightDir;
    
    this(ClusteredLightManager clm, Owner o)
    {
        super(o);
        
        lightManager = clm;

        viewMatrixLoc = glGetUniformLocation(shaderProgram, "viewMatrix");
        modelViewMatrixLoc = glGetUniformLocation(shaderProgram, "modelViewMatrix");
        projectionMatrixLoc = glGetUniformLocation(shaderProgram, "projectionMatrix");
        normalMatrixLoc = glGetUniformLocation(shaderProgram, "normalMatrix");
        invViewMatrixLoc = glGetUniformLocation(shaderProgram, "invViewMatrix");
        
        prevModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "prevModelViewProjMatrix");
        blurModelViewProjMatrixLoc = glGetUniformLocation(shaderProgram, "blurModelViewProjMatrix");
        
        shadowMatrix1Loc = glGetUniformLocation(shaderProgram, "shadowMatrix1");
        shadowMatrix2Loc = glGetUniformLocation(shaderProgram, "shadowMatrix2");
        shadowMatrix3Loc = glGetUniformLocation(shaderProgram, "shadowMatrix3");
        shadowTextureArrayLoc = glGetUniformLocation(shaderProgram, "shadowTextureArray");
        shadowTextureSizeLoc = glGetUniformLocation(shaderProgram, "shadowTextureSize");
        useShadowsLoc = glGetUniformLocation(shaderProgram, "useShadows");
        shadowColorLoc = glGetUniformLocation(shaderProgram, "shadowColor");
        shadowBrightnessLoc = glGetUniformLocation(shaderProgram, "shadowBrightness");
        useHeightCorrectedShadowsLoc = glGetUniformLocation(shaderProgram, "useHeightCorrectedShadows");

        pbrTextureLoc = glGetUniformLocation(shaderProgram, "pbrTexture");
       
        parallaxMethodLoc = glGetUniformLocation(shaderProgram, "parallaxMethod");
        parallaxScaleLoc = glGetUniformLocation(shaderProgram, "parallaxScale");
        parallaxBiasLoc = glGetUniformLocation(shaderProgram, "parallaxBias");
        
        diffuseTextureLoc = glGetUniformLocation(shaderProgram, "diffuseTexture");
        normalTextureLoc = glGetUniformLocation(shaderProgram, "normalTexture");
        emissionTextureLoc = glGetUniformLocation(shaderProgram, "emissionTexture");
        emissionEnergyLoc = glGetUniformLocation(shaderProgram, "emissionEnergy");
        
        environmentMapLoc = glGetUniformLocation(shaderProgram, "environmentMap");
        useEnvironmentMapLoc = glGetUniformLocation(shaderProgram, "useEnvironmentMap");
        
        environmentColorLoc = glGetUniformLocation(shaderProgram, "environmentColor");
        sunDirectionLoc = glGetUniformLocation(shaderProgram, "sunDirection");
        sunColorLoc = glGetUniformLocation(shaderProgram, "sunColor");
        sunEnergyLoc = glGetUniformLocation(shaderProgram, "sunEnergy");
        fogStartLoc = glGetUniformLocation(shaderProgram, "fogStart");
        fogEndLoc = glGetUniformLocation(shaderProgram, "fogEnd");
        fogColorLoc = glGetUniformLocation(shaderProgram, "fogColor");
        groundColorLoc = glGetUniformLocation(shaderProgram, "groundColor");
        groundEnergyLoc = glGetUniformLocation(shaderProgram, "groundEnergy");
        
        skyZenithColorLoc = glGetUniformLocation(shaderProgram, "skyZenithColor");
        skyHorizonColorLoc = glGetUniformLocation(shaderProgram, "skyHorizonColor");
        skyEnergyLoc = glGetUniformLocation(shaderProgram, "skyEnergy");
        
        clusterTextureLoc = glGetUniformLocation(shaderProgram, "lightClusterTexture");
        invLightDomainSizeLoc = glGetUniformLocation(shaderProgram, "invLightDomainSize");
        lightsTextureLoc = glGetUniformLocation(shaderProgram, "lightsTexture");
        indexTextureLoc = glGetUniformLocation(shaderProgram, "lightIndexTexture");
        
        blurMaskLoc = glGetUniformLocation(shaderProgram, "blurMask");
        
        shadedLoc = glGetUniformLocation(shaderProgram, "shaded");
        transparencyLoc = glGetUniformLocation(shaderProgram, "transparency");
        usePCFLoc = glGetUniformLocation(shaderProgram, "usePCF");
    }
    
    override void bind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        auto inormal = "normal" in mat.inputs;
        auto iheight = "height" in mat.inputs;
        auto iemission = "emission" in mat.inputs;
        auto iEnergy = "energy" in mat.inputs;
        auto ipbr = "pbr" in mat.inputs;
        auto iroughness = "roughness" in mat.inputs;
        auto imetallic = "metallic" in mat.inputs;
        bool fogEnabled = boolProp(mat, "fogEnabled");
        bool shadowsEnabled = boolProp(mat, "shadowsEnabled");
        int parallaxMethod = intProp(mat, "parallax");
        if (parallaxMethod > ParallaxOcclusionMapping)
            parallaxMethod = ParallaxOcclusionMapping;
        if (parallaxMethod < 0)
            parallaxMethod = 0;
                
        auto ishadeless = "shadeless" in mat.inputs;
        auto itransparency = "transparency" in mat.inputs;
        auto ishadowFilter = "shadowFilter" in mat.inputs;
        
        glUseProgram(shaderProgram);
        
        glUniform1f(blurMaskLoc, rc.blurMask);
        
        // Matrices
        glUniformMatrix4fv(viewMatrixLoc, 1, GL_FALSE, rc.viewMatrix.arrayof.ptr);
        glUniformMatrix4fv(modelViewMatrixLoc, 1, GL_FALSE, rc.modelViewMatrix.arrayof.ptr);
        glUniformMatrix4fv(projectionMatrixLoc, 1, GL_FALSE, rc.projectionMatrix.arrayof.ptr);
        glUniformMatrix4fv(normalMatrixLoc, 1, GL_FALSE, rc.normalMatrix.arrayof.ptr);
        glUniformMatrix4fv(invViewMatrixLoc, 1, GL_FALSE, rc.invViewMatrix.arrayof.ptr);
        
        glUniformMatrix4fv(prevModelViewProjMatrixLoc, 1, GL_FALSE, rc.prevModelViewProjMatrix.arrayof.ptr);
        glUniformMatrix4fv(blurModelViewProjMatrixLoc, 1, GL_FALSE, rc.blurModelViewProjMatrix.arrayof.ptr);
        
        // Environment parameters
        Color4f environmentColor = Color4f(0.0f, 0.0f, 0.0f, 1.0f);
        Vector4f sunHGVector = Vector4f(0.0f, 1.0f, 0.0, 0.0f);
        Vector3f sunColor = Vector3f(1.0f, 1.0f, 1.0f);
        float sunEnergy = 100.0f;
        if (rc.environment)
        {
            environmentColor = rc.environment.ambientConstant;
            sunHGVector = Vector4f(rc.environment.sunDirection);
            sunHGVector.w = 0.0;
            sunColor = rc.environment.sunColor;
            sunEnergy = rc.environment.sunEnergy;
        }
        glUniform4fv(environmentColorLoc, 1, environmentColor.arrayof.ptr);
        Vector3f sunDirectionEye = sunHGVector * rc.viewMatrix;
        glUniform3fv(sunDirectionLoc, 1, sunDirectionEye.arrayof.ptr);
        glUniform3fv(sunColorLoc, 1, sunColor.arrayof.ptr);
        glUniform1f(sunEnergyLoc, sunEnergy);
        Color4f fogColor = Color4f(0.0f, 0.0f, 0.0f, 1.0f);
        float fogStart = float.max;
        float fogEnd = float.max;
        if (fogEnabled)
        {
            if (rc.environment)
            {                
                fogColor = rc.environment.fogColor;
                fogStart = rc.environment.fogStart;
                fogEnd = rc.environment.fogEnd;
            }
        }
        glUniform4fv(fogColorLoc, 1, fogColor.arrayof.ptr);
        glUniform1f(fogStartLoc, fogStart);
        glUniform1f(fogEndLoc, fogEnd);
        
        Color4f skyZenithColor = environmentColor;
        Color4f skyHorizonColor = environmentColor;
        float skyEnergy = 1.0f;
        Color4f groundColor = environmentColor;
        float groundEnergy = 1.0f;
        if (rc.environment)
        {
            skyZenithColor = rc.environment.skyZenithColor;
            skyHorizonColor = rc.environment.skyHorizonColor;
            groundColor = rc.environment.groundColor;
            skyEnergy = rc.environment.skyEnergy;
            groundEnergy = rc.environment.groundEnergy;
        }
        glUniform3fv(skyZenithColorLoc, 1, skyZenithColor.arrayof.ptr);
        glUniform3fv(skyHorizonColorLoc, 1, skyHorizonColor.arrayof.ptr);
        glUniform1f(skyEnergyLoc, skyEnergy);
        glUniform3fv(groundColorLoc, 1, groundColor.arrayof.ptr);
        glUniform1f(groundEnergyLoc, groundEnergy);
                
        // Texture 0 - diffuse texture
        if (idiffuse.texture is null)
        {
            Color4f color = Color4f(idiffuse.asVector4f);
            idiffuse.texture = makeOnePixelTexture(mat, color);
        }
        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.bind();
        glUniform1i(diffuseTextureLoc, 0);
        
        // Texture 1 - normal map + parallax map
        float parallaxScale = 0.03f;
        float parallaxBias = -0.01f;
        bool normalTexturePrepared = inormal.texture !is null;
        if (normalTexturePrepared) 
            normalTexturePrepared = inormal.texture.image.channels == 4;
        if (!normalTexturePrepared)
        {
            if (inormal.texture is null)
            {
                Color4f color = Color4f(0.5f, 0.5f, 1.0f, 0.0f); // default normal pointing upwards
                inormal.texture = makeOnePixelTexture(mat, color);
            }
            else
            {
                if (iheight.texture !is null)
                    packAlphaToTexture(inormal.texture, iheight.texture);
                else
                    packAlphaToTexture(inormal.texture, 0.0f);
            }
        }
        glActiveTexture(GL_TEXTURE1);
        inormal.texture.bind();
        glUniform1i(normalTextureLoc, 1);
        glUniform1f(parallaxScaleLoc, parallaxScale);
        glUniform1f(parallaxBiasLoc, parallaxBias);
        glUniform1i(parallaxMethodLoc, parallaxMethod);
        
        // Texture 2 is - PBR maps (roughness + metallic)
        if (ipbr is null)
        {
            mat.setInput("pbr", 0.0f);
            ipbr = "pbr" in mat.inputs;
        }
        
        if (ipbr.texture is null)
        {       
            ipbr.texture = makeTextureFrom(mat, *iroughness, *imetallic, materialInput(0.0f), materialInput(0.0f));
        }
        glActiveTexture(GL_TEXTURE2);
        glUniform1i(pbrTextureLoc, 2);
        ipbr.texture.bind();
        
        // Texture 3 - emission map
        if (iemission.texture is null)
        {
            Color4f color = Color4f(iemission.asVector4f);
            iemission.texture = makeOnePixelTexture(mat, color);
        }
        glActiveTexture(GL_TEXTURE3);
        iemission.texture.bind();
        glUniform1i(emissionTextureLoc, 3);
        glUniform1f(emissionEnergyLoc, iEnergy.asFloat); 
        
        // Texture 4 - environment map
        bool useEnvmap = false;
        if (rc.environment)
        {
            if (rc.environment.environmentMap)
                useEnvmap = true;
        }
        
        if (useEnvmap)
        {
            glActiveTexture(GL_TEXTURE4);
            rc.environment.environmentMap.bind();
            glUniform1i(useEnvironmentMapLoc, 1);
        }
        else
        {
            glUniform1i(useEnvironmentMapLoc, 0);
        }
        glUniform1i(environmentMapLoc, 4);
        
        // Texture 5 - shadow map cascades (3 layer texture array)
        float shadowBrightness = 0.1f;
        bool useHeightCorrectedShadows = false;
        Color4f shadowColor = Color4f(1.0f, 1.0f, 1.0f, 1.0f);
        if (shadowMap && shadowsEnabled)
        {
            glActiveTexture(GL_TEXTURE5);
            glBindTexture(GL_TEXTURE_2D_ARRAY, shadowMap.depthTexture);

            glUniform1i(shadowTextureArrayLoc, 5);
            glUniform1f(shadowTextureSizeLoc, cast(float)shadowMap.size);
            glUniformMatrix4fv(shadowMatrix1Loc, 1, 0, shadowMap.area1.shadowMatrix.arrayof.ptr);
            glUniformMatrix4fv(shadowMatrix2Loc, 1, 0, shadowMap.area2.shadowMatrix.arrayof.ptr);
            glUniformMatrix4fv(shadowMatrix3Loc, 1, 0, shadowMap.area3.shadowMatrix.arrayof.ptr);
            glUniform1i(useShadowsLoc, 1);            
            // TODO: shadowFilter
            
            shadowBrightness = shadowMap.shadowBrightness;
            useHeightCorrectedShadows = shadowMap.useHeightCorrectedShadows;
            shadowColor = shadowMap.shadowColor;
        }
        else
        {        
            glUniformMatrix4fv(shadowMatrix1Loc, 1, 0, defaultShadowMat.arrayof.ptr);
            glUniformMatrix4fv(shadowMatrix2Loc, 1, 0, defaultShadowMat.arrayof.ptr);
            glUniformMatrix4fv(shadowMatrix3Loc, 1, 0, defaultShadowMat.arrayof.ptr);
            glUniform1i(useShadowsLoc, 0);
        }
        glUniform4fv(shadowColorLoc, 1, shadowColor.arrayof.ptr);
        glUniform1f(shadowBrightnessLoc, shadowBrightness);
        glUniform1i(useHeightCorrectedShadowsLoc, useHeightCorrectedShadows);

        // Texture 6 - light clusters
        glActiveTexture(GL_TEXTURE6);
        lightManager.bindClusterTexture();
        glUniform1i(clusterTextureLoc, 6);
        glUniform1f(invLightDomainSizeLoc, lightManager.invSceneSize);
        
        // Texture 7 - light data
        glActiveTexture(GL_TEXTURE7);
        lightManager.bindLightTexture();
        glUniform1i(lightsTextureLoc, 7);
        
        // Texture 8 - light indices per cluster
        glActiveTexture(GL_TEXTURE8);
        lightManager.bindIndexTexture();
        glUniform1i(indexTextureLoc, 8);
        
        bool shaded = true;
        if (ishadeless)
            shaded = !(ishadeless.asBool);
        glUniform1i(shadedLoc, shaded);

        float transparency = 1.0f;
        if (itransparency)
            transparency = itransparency.asFloat;
        glUniform1f(transparencyLoc, transparency);
        
        bool usePCF = false;
        if (ishadowFilter)
            usePCF = (ishadowFilter.asInteger == ShadowFilterPCF);
        glUniform1i(usePCFLoc, usePCF);
        
        glActiveTexture(GL_TEXTURE0);
    }
    
    override void unbind(GenericMaterial mat, RenderingContext* rc)
    {
        auto idiffuse = "diffuse" in mat.inputs;
        auto inormal = "normal" in mat.inputs;
        auto iemission = "emission" in mat.inputs;
        auto ipbr = "pbr" in mat.inputs;
        
        glActiveTexture(GL_TEXTURE0);
        idiffuse.texture.unbind();
        
        glActiveTexture(GL_TEXTURE1);
        inormal.texture.unbind();
        
        glActiveTexture(GL_TEXTURE1);
        ipbr.texture.unbind();
        
        glActiveTexture(GL_TEXTURE3);
        iemission.texture.unbind();
        
        bool useEnvmap = false;
        if (rc.environment)
        {
            if (rc.environment.environmentMap)
                useEnvmap = true;
        }
        
        if (useEnvmap)
        {
            glActiveTexture(GL_TEXTURE4);
            rc.environment.environmentMap.unbind();
        }

        glActiveTexture(GL_TEXTURE5);
        glBindTexture(GL_TEXTURE_2D_ARRAY, 0);
        
        glActiveTexture(GL_TEXTURE6);
        lightManager.unbindClusterTexture();
        
        glActiveTexture(GL_TEXTURE7);
        lightManager.unbindLightTexture();
        
        glActiveTexture(GL_TEXTURE8);
        lightManager.unbindIndexTexture();
        
        glActiveTexture(GL_TEXTURE0);
        
        glUseProgram(0);
    }
}
