#version 430 core
#extension GL_ARB_compute_shader: enable
#extension GL_ARB_shader_storage_buffer_object: enable

// TODO: change work group size here and in nbody.cpp
#define WORK_GROUP_SIZE_VELPOS 32
#define EPSILON 0.0001

layout(std430, binding = 0) buffer _pCloth1 { // cloth positions in previous timestep
    vec4 pCloth1[];
};
layout(std430, binding = 1) buffer _pCloth2 { // cloth positions in new timestep
    vec4 pCloth2[];
};
layout(std430, binding = 2) readonly buffer _bodyPositions { // influencee "rigidbody"
    vec4 pBody[];
};
layout(std430, binding = 3) readonly buffer _bodyTriangles {
    vec4 bodyTriangles[];
};
layout(std430, binding = 4) buffer _collisionConstraints { // vec4s of normal dir and distance 
    vec4 pClothCollisionConstraints[];
};
layout(std430, binding = 5) buffer _debug { // vec4s of debug data
    vec4 debug[];
};

layout(local_size_x = WORK_GROUP_SIZE_VELPOS, local_size_y = 1, local_size_z = 1) in;

layout(location = 0) uniform int numTriangles;
layout(location = 1) uniform int numPositions;
layout(location = 2) uniform float staticConstraintBounce;

vec3 nearestPointOnTriangle(vec3 pos, vec3 v0, vec3 v1, vec3 v2)
{
    // this is an approximation that will merely return the nearest of the three verts, the centroid,
    // and each of the three edge midpoints
    vec3 nearest = (v0 + v1 + v2) / 3.0;
    float minLength = length(nearest - pos);

    float candidate = length(v0 - pos);
    if (candidate < minLength) {
        nearest = v0;
        minLength = candidate;
    }
    candidate = length(v1 - pos);
    if (candidate < minLength) {
        nearest = v1;
        minLength = candidate;
    }
    candidate = length(v2 - pos);
    if (candidate < minLength) {
        nearest = v2;
        minLength = candidate;
    }
    // check edge midpoints
    vec3 vM = (v0 + v1) / 2;
    candidate = length(vM - pos);
    if (candidate < minLength) {
        nearest = vM;
        minLength = candidate;
    }
    vM = (v1 + v2) / 2;
    candidate = length(vM - pos);
    if (candidate < minLength) {
        nearest = vM;
        minLength = candidate;
    }
    vM = (v2 + v0) / 2;
    candidate = length(vM - pos);
    if (candidate < minLength) {
        nearest = vM;
        minLength = candidate;
    }
    return nearest;
}

void generateStaticConstraint(vec3 pos) {
    uint idx = gl_GlobalInvocationID.x;

    // static constraint: generate a "point of entry" approximating the closest
    // point on the mesh to the pos from the last timestep (pos).
    // Move the position in the last timestep based on this "point of entry" and
    // use the normal at this point to generate a constraint that will get
    // the point in this timestep out.

    vec3 triangle = bodyTriangles[0].xyz;
    vec3 v0 = pBody[int(triangle.x)].xyz;
    vec3 v1 = pBody[int(triangle.y)].xyz;
    vec3 v2 = pBody[int(triangle.z)].xyz;
    vec3 nearestPoint = nearestPointOnTriangle(pos, v0, v1, v2);
    vec3 nearestNormal = normalize(cross(v1 - v0, v2 - v0));
    float nearestDistance = length(nearestPoint - pos);
    vec3 candidatePoint;
    float candidateDistance;

    for (int i = 1; i < numTriangles; i++) {

        triangle = bodyTriangles[i].xyz;
        v0 = pBody[int(triangle.x)].xyz;
        v1 = pBody[int(triangle.y)].xyz;
        v2 = pBody[int(triangle.z)].xyz;
        candidatePoint = nearestPointOnTriangle(pos, v0, v1, v2);
        candidateDistance = length(candidatePoint - pos);
        if (candidateDistance < nearestDistance) {
            nearestDistance = candidateDistance;
            nearestPoint = candidatePoint;
            nearestNormal = normalize(cross(v1 - v0, v2 - v0));
        }
    }

    // move the position in the last timestep over to nearestPoint
    pCloth1[idx].xyz = nearestPoint + nearestNormal * staticConstraintBounce;
    pClothCollisionConstraints[idx] = vec4(nearestNormal, 1.0);
    return;
}

float mollerTrumboreIntersectTriangle(vec3 orig, vec3 dir, vec3 v0, vec3 v1, vec3 v2)
{
    
    // adapted from Moller-Trumbore intersection algorithm pseudocode on wikipedia
    vec3 e1, e2; // Edge1, Edge2
    vec3 P, Q, T;
    float det, inv_det, u, v;
    float t;
    
    // vectors for edges sharing V1
    e1 = v1 - v0;
    e2 = v2 - v0;

    // begin calculating determinant - also used to calculate u param
    P = cross(dir, e2);

    // if determinant is near zero, ray lies in plane of triangle
    det = dot(e1, P);
    // NOT culling
    if (det > -EPSILON && det < EPSILON) return -1.0;
    inv_det = 1.0 / det;

    // calculate distance from v0 to ray origin
    T = orig - v0;

    // calculate u parameter and test bound
    u = dot(T, P) * inv_det;
    // the intersection lies outside of the triangle
    if (u < 0.0 || u > 1.0) return -1.0;

    // prepare to test v parameter
    Q = cross(T, e1);

    // calculate v param and test bound
    v = dot(dir, Q) * inv_det;

    // the intersection is outside the triangle?
    if (v < 0.0 || (u + v) > 1.0) return -1.0;

    t = dot(e2, Q) * inv_det;

    if (t > 0.0) {
        return t;
    }

    return -1.0;
}

float altIntersectTriangle(vec3 orig, vec3 dir, vec3 v0, vec3 v1, vec3 v2)
{
    // adapted from http://undernones.blogspot.com/2010/12/gpu-ray-tracing-with-glsl.html
    // buggy? -> in some sims but not others. ditto with method above. wat
    vec3 u, v, n; // triangle vectors
    vec3 w0, w;  // ray float
    float r, a, b; // params to calc ray-plane intersect

    // get triangle edge vectors and plane normal
    u = v1 - v0;
    v = v2 - v0;
    n = cross(u, v);

    w0 = orig - v0;
    a = -dot(n, w0);
    b = dot(n, dir);
    if (abs(b) < 1e-5)
    {
        // ray is parallel to triangle plane, and thus can never intersect.
        return -1.0;
    }

    // get intersect point of ray with triangle plane
    r = a / b;
    if (r <= 0.0)
        return -1.0; // ray goes away from triangle.

    // baycentric coordinates part
    vec3 I = orig + r * dir;
    float uu, uv, vv, wu, wv, D;
    uu = dot(u, u);
    uv = dot(u, v);
    vv = dot(v, v);
    w = I - v0;
    wu = dot(w, u);
    wv = dot(w, v);
    D = uv * uv - uu * vv;

    // get and test parametric coords
    float s, t;
    s = (uv * wv - vv * wu) / D;
    if (s < 0.0 || s > 1.0)
        return -1.0;
    t = (uv * wu - uu * wv) / D;
    if (t < 0.0 || (s + t) > 1.0)
        return -1.0;

    return (r >= 0.0) ? r : -1.0;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= numPositions) return;

    // check if there's already a valid constraint. if so, do nothing
    if (pClothCollisionConstraints[idx].w >= 0.0) return; 

    // also, if this is infinite weighted, do nothing
    // inverse mass is the w in the position
    if (pCloth1[idx].w < EPSILON) return;

    vec3 pos = pCloth1[idx].xyz; // prev timestep
    vec3 lookAt = pCloth2[idx].xyz; // next timestep
    float dirScale = length(lookAt - pos);
    vec3 dir = normalize(lookAt - pos);

    vec4 collisionConstraint = vec4(-1.0); // a bogus collisionConstraint

    // if there's an odd number of collisions, we're inside the mesh already
    int numCollisions = 0; // which means we need a static constraint (addtl handling here)

    debug[idx] = vec4(-1.0);
    vec3 debugPos;

    // check against every triangle in the mesh.
    for (int i = 0; i < numTriangles; i++) {

        vec3 triangle = bodyTriangles[i].xyz;
        vec3 v0 = pBody[int(triangle.x)].xyz;
        vec3 v1 = pBody[int(triangle.y)].xyz;
        vec3 v2 = pBody[int(triangle.z)].xyz;
        vec3 norm = normalize(cross(v1 - v0, v2 - v0));

        // b/c intersectTriangle gets us a distance with a normalized dir vector
        // intersectTriangle = realLength * dirScale
        // intersectTriangle / dirScale = realLength
        float collisionT = mollerTrumboreIntersectTriangle(pos, dir, v0, v1, v2);
        // collision out of bounds
        if (collisionT > -EPSILON) {
            numCollisions++;
            debugPos = pos + (collisionT / dirScale) * (lookAt - pos);
        }
        collisionT /= dirScale;
        if (collisionT > 1.0 || collisionT < 0.0) {
            continue;
        }
        //use the nearest collision with distance less than 1
        if (collisionConstraint.w < 0.0 ||
            collisionT < collisionConstraint.w) {
            collisionConstraint.xyz = norm;
            collisionConstraint.w = collisionT;
        }
    }
    debug[idx].xyz = debugPos;
    debug[idx].w = numCollisions;

    // if the number of collisions is odd
    // and no triangle was crossed in the timestep, <- ? seems logical but leads to odd results
    // generate a static constraint instead.
    if (numCollisions % 2 != 0) {//} && collisionConstraint.w < 0.0) {
        //pCloth2[idx].xyz = debugPos;//vec3(0.0, 0.0, -numCollisions); // debug
        generateStaticConstraint(pos);
        return;
    }

    pClothCollisionConstraints[idx] = collisionConstraint;
}
