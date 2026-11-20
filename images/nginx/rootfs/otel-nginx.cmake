# The contrib module depends on project_nginx. Its upstream nginx.cmake
# downloads a second copy of NGINX. Use the configured tree from build.sh
# so the module sees the fork's patched structs and generated headers.
add_custom_target(project_nginx)

foreach(dir IN ITEMS objs src/core src/os/unix src/event src/event/quic
                     src/http src/http/modules src/http/v2 src/http/v3)
  list(APPEND NGINX_INCLUDE_DIRS "${NGINX_SOURCE_DIR}/${dir}")
endforeach()
