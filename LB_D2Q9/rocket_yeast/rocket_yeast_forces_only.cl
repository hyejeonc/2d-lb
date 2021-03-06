__kernel void
update_feq(__global __write_only float *feq_global,
           __global __read_only float *rho_global,
           __global __read_only float *u_global,
           __global __read_only float *v_global,
           __constant float *w,
           __constant int *cx,
           __constant int *cy,
           const float cs,
           const int nx, const int ny, const int num_populations)
{
    //Input should be a 2d workgroup. But, we loop over a 4d array...
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    const int two_d_index = y*nx + x;

    if ((x < nx) && (y < ny)){

        const float u = u_global[two_d_index];
        const float v = v_global[two_d_index];

        // rho is three-dimensional now...have to loop over every field.
        for (int field_num=0; field_num < num_populations; field_num++){
            int three_d_index = field_num*nx*ny + two_d_index;
            float rho = rho_global[three_d_index];
            // Now loop over every jumper
            for(int jump_id=0; jump_id < 9; jump_id++){
                int four_d_index = jump_id*num_populations*nx*ny + three_d_index;

                float cur_w = w[jump_id];
                int cur_cx = cx[jump_id];
                int cur_cy = cy[jump_id];

                float cur_c_dot_u = cur_cx*u + cur_cy*v;

                float new_feq = cur_w*rho*(1.f + cur_c_dot_u/(cs*cs));

                feq_global[four_d_index] = new_feq;
            }
        }
    }
}

__kernel void
update_surf_tension(__global float *S_global,
                __global __read_only float *rho_global,
                const float c_o, const float alpha,
                const int nx, const int ny, const int surf_index)
{
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if ((x < nx) && (y < ny)){
        const int two_d_index = y*nx + x;
        int three_d_index = surf_index*ny*nx + two_d_index;

        float cur_rho = rho_global[three_d_index];
        if (cur_rho < 0) cur_rho = 0;
        S_global[two_d_index] = pow(1.f - exp(-cur_rho/c_o), alpha);
    }
}



__kernel void
update_u_and_v(__global float *u_global,
               __global float *v_global,
               __global __read_only float *pseudo_force_x,
               __global __read_only float *pseudo_force_y,
               __global __read_only float *surface_force_x,
               __global __read_only float *surface_force_y,
               const int nx, const int ny, const int num_populations)
{
    // Assumes that u and v are imposed. Can be changed later.
    //This *MUST* be run after move_bc's, as that takes care of BC's
    //Input should be a 2d workgroup!
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if ((x < nx) && (y < ny)){
        const int two_d_index = y*nx + x;

        float force_x_sum = pseudo_force_x[two_d_index] + surface_force_x[two_d_index];
        float force_y_sum = pseudo_force_y[two_d_index] + surface_force_y[two_d_index];

        u_global[two_d_index] = force_x_sum;
        v_global[two_d_index] = force_y_sum;
    }
}

__kernel void
update_rho(__global __read_only float *f_global,
             __global __write_only float *rho_global,
             const int nx, const int ny, const int num_populations)
{
    // Assumes that u and v are imposed. Can be changed later.
    //This *MUST* be run after move_bc's, as that takes care of BC's
    //Input should be a 2d workgroup!
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if ((x < nx) && (y < ny)){
        const int two_d_index = y*nx + x;
        // Loop over fields.
        for(int field_num = 0; field_num < num_populations; field_num++){
            int three_d_index = field_num*nx*ny + two_d_index;

            float f_sum = 0;
            for(int jump_id = 0; jump_id < 9; jump_id++){
                f_sum += f_global[jump_id*num_populations*nx*ny + three_d_index];
            }
            rho_global[three_d_index] = f_sum;
        }
    }
}

__kernel void
collide_particles(__global float *f_global,
                            __global __read_only float *feq_global,
                            __global __read_only float *rho_global,
                            const float omega, const float omega_c,
                            const float G, const float Gc,
                            __constant float *w,
                            const int nx, const int ny, const int num_populations)
{
    //Input should be a 2d workgroup! Loop over the third dimension.
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if ((x < nx) && (y < ny)){

        const int two_d_index = y*nx + x;

        float cur_rho = rho_global[0*ny*nx + two_d_index]; // Density
        float cur_c = rho_global[1*ny*nx + two_d_index]; // Surfactant concentration

        //****** POPULATION ******
        int cur_field = 0;

        // No growth when you are more dense than 1...but you don't shrink in amplitude!!!
        float all_growth = G * cur_rho * (1 - cur_rho);
        if (cur_rho > 1.0) all_growth = 0;

        int three_d_index = cur_field*ny*nx + two_d_index;
        for(int jump_id=0; jump_id < 9; jump_id++){
            int four_d_index = jump_id*num_populations*ny*nx + three_d_index;

            float f = f_global[four_d_index];
            float feq = feq_global[four_d_index];
            float cur_w = w[jump_id];

            float relax = f*(1-omega) + omega*feq;
            float growth = cur_w*all_growth;

            float new_f = relax + growth;
            if(new_f < 0) new_f = 0; // For stability?

            f_global[four_d_index] = new_f;
        }
        //****** Surfactant ******
        cur_field = 1;

        all_growth = Gc*cur_rho;

        three_d_index = cur_field*ny*nx + two_d_index;
        for(int jump_id=0; jump_id < 9; jump_id++){
            int four_d_index = jump_id*num_populations*ny*nx + three_d_index;

            float f = f_global[four_d_index];
            float feq = feq_global[four_d_index];
            float cur_w = w[jump_id];

            float relax = f*(1-omega_c) + omega_c*feq;
            //Nutrients are depleted at the same rate cells grow...so subtract
            float growth = cur_w*all_growth;

            f_global[four_d_index] = relax + growth;
        }
    }
}

__kernel void
move_periodic(__global __read_only float *f_global,
              __global __write_only float *f_streamed_global,
              __constant int *cx,
              __constant int *cy,
              const int nx, const int ny, const int num_populations)
{
    /* Moves you assuming periodic BC's. */
    //Input should be a 2d workgroup!
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if ((x < nx) && (y < ny)){
        for(int jump_id = 0; jump_id < 9; jump_id++){
            int cur_cx = cx[jump_id];
            int cur_cy = cy[jump_id];

            //Make sure that you don't go out of the system

            int stream_x = x + cur_cx;
            int stream_y = y + cur_cy;

            if (stream_x == nx) stream_x = 0;
            if (stream_x < 0) stream_x = nx - 1;

            if (stream_y == ny) stream_y = 0;
            if (stream_y < 0) stream_y = ny - 1;

            // Set stream values
            for(int field_num = 0; field_num < num_populations; field_num++){
                int slice = jump_id*num_populations*nx*ny + field_num*nx*ny;

                int old_4d_index = slice + y*nx + x;
                int new_4d_index = slice + stream_y*nx + stream_x;

                f_streamed_global[new_4d_index] = f_global[old_4d_index];
            }
        }
    }
}

__kernel void
update_pressure_force(__global __read_only float *rho_global,
                    const int pop_index,
                    __global float *pseudo_force_x,
                    __global float *pseudo_force_y,
                    const float G_chen,
                    const float rho_o,
                    const float cs,
                    __constant int *cx,
                    __constant int *cy,
                    __constant float *w,
                    __local float *rho_local,
                    const int nx, const int ny,
                    const int buf_nx, const int buf_ny,
                    const int halo)
{
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    // Have to use local memory where you read in everything around you in the workgroup.
    // Otherwise, you are actually doing 9x the work of what you have to...painful.

    // Local position relative to (0, 0) in workgroup
    const int lx = get_local_id(0);
    const int ly = get_local_id(1);

    // coordinates of the upper left corner of the buffer in image
    // space, including halo
    const int buf_corner_x = x - lx - halo;
    const int buf_corner_y = y - ly - halo;

    // coordinates of our pixel in the local buffer
    const int buf_x = lx + halo;
    const int buf_y = ly + halo;

    // 1D index of thread within our work-group
    const int idx_1D = ly * get_local_size(0) + lx;

    barrier(CLK_LOCAL_MEM_FENCE);
    if (idx_1D < buf_nx) {
        for (int row = 0; row < buf_ny; row++) {
            int temp_x = buf_corner_x + idx_1D;
            int temp_y = buf_corner_y + row;

            //Painfully deal with BC's...i.e. use periodic BC's.
            if (temp_x >= nx) temp_x -= nx;
            if (temp_x < 0) temp_x += nx;

            if (temp_y >= ny) temp_y -= ny;
            if (temp_y < 0) temp_y += ny;

            rho_local[row*buf_nx + idx_1D] = rho_global[pop_index*ny*nx + temp_y*nx + temp_x];

        }
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    //Now that all desired psi are read in, do the multiplication
    if ((x < nx) && (y < ny)){
        const int old_2d_buf_index = buf_y*buf_nx + buf_x;
        const float middle_rho = rho_local[old_2d_buf_index];

        float rho_grad_x = 0;
        float rho_grad_y = 0;
        for(int jump_id = 0; jump_id < 9; jump_id++){
            int cur_cx = cx[jump_id];
            int cur_cy = cy[jump_id];
            float cur_w = w[jump_id];

            //Get the shifted positions
            int stream_buf_x = buf_x + cur_cx;
            int stream_buf_y = buf_y + cur_cy;

            int new_2d_buf_index = stream_buf_y*buf_nx + stream_buf_x;

            float new_rho = rho_local[new_2d_buf_index];
            rho_grad_x += cur_w * cur_cx * new_rho;
            rho_grad_y += cur_w * cur_cy * new_rho;
        }
        const int two_d_index = y*nx + x;

        const float inv_cs_sq = 1./(cs*cs);
        rho_grad_x *= inv_cs_sq; // To make the gradient actually correct
        rho_grad_y *= inv_cs_sq;

        //Now calculate the pressure gradient

        pseudo_force_x[two_d_index] = -G_chen * rho_grad_x * (middle_rho - rho_o);
        pseudo_force_y[two_d_index] = -G_chen * rho_grad_y * (middle_rho - rho_o);
    }
}

__kernel void
update_surface_forces(__global __read_only float *S_global,
               __global __write_only float *surface_force_x,
               __global __write_only float *surface_force_y,
               const int surf_index,
               const float cs,
               const float epsilon,
               __constant int *cx,
               __constant int *cy,
               __constant float *w,
               __local float *S_local,
               const int nx, const int ny,
               const int buf_nx, const int buf_ny,
               const int halo)
{
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    // Have to use local memory where you read in everything around you in the workgroup.
    // Otherwise, you are actually doing 9x the work of what you have to...painful.

    // Local position relative to (0, 0) in workgroup
    const int lx = get_local_id(0);
    const int ly = get_local_id(1);

    // coordinates of the upper left corner of the buffer in image
    // space, including halo
    const int buf_corner_x = x - lx - halo;
    const int buf_corner_y = y - ly - halo;

    // coordinates of our pixel in the local buffer
    const int buf_x = lx + halo;
    const int buf_y = ly + halo;

    // 1D index of thread within our work-group
    const int idx_1D = ly * get_local_size(0) + lx;

    barrier(CLK_LOCAL_MEM_FENCE);
    if (idx_1D < buf_nx) {
        for (int row = 0; row < buf_ny; row++) {
            int temp_x = buf_corner_x + idx_1D;
            int temp_y = buf_corner_y + row;

            //Painfully deal with BC's...i.e. use periodic BC's.
            if (temp_x >= nx) temp_x -= nx;
            if (temp_x < 0) temp_x += nx;

            if (temp_y >= ny) temp_y -= ny;
            if (temp_y < 0) temp_y += ny;

            S_local[row*buf_nx + idx_1D] = S_global[temp_y*nx + temp_x];

        }
    }
    barrier(CLK_LOCAL_MEM_FENCE);

    //Now that all desired psi are read in, do the multiplication
    if ((x < nx) && (y < ny)){
        const int old_2d_buf_index = buf_y*buf_nx + buf_x;

        float grad_x = 0;
        float grad_y = 0;
        for(int jump_id = 0; jump_id < 9; jump_id++){
            int cur_cx = cx[jump_id];
            int cur_cy = cy[jump_id];
            float cur_w = w[jump_id];

            //Get the shifted positions
            int stream_buf_x = buf_x + cur_cx;
            int stream_buf_y = buf_y + cur_cy;

            int new_2d_buf_index = stream_buf_y*buf_nx + stream_buf_x;

            float cur_S = S_local[new_2d_buf_index];
            grad_x += cur_w * cur_cx * cur_S;
            grad_y += cur_w * cur_cy * cur_S;
        }
        const int two_d_index = y*nx + x;
        const float inv_cs_sq = 1./(cs*cs);
        surface_force_x[two_d_index] = -epsilon * inv_cs_sq * grad_x;
        surface_force_y[two_d_index] = -epsilon * inv_cs_sq * grad_y;
    }
}

