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
update_hydro(__global float *f_global,
             __global float *u_global,
             __global float *v_global,
             __global float *rho_global,
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
                  __constant float *omega,
                  __constant float *G,
                  __constant float *w,
                  const int nx, const int ny, const int num_populations)
{
    //Input should be a 2d workgroup! Loop over the third dimension.
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if ((x < nx) && (y < ny)){

        const int two_d_index = y*nx + x;

        float rho_tot = 0;
        for(int field_num=0; field_num < num_populations; field_num++){ //Loop over populations first
            int three_d_index = field_num*ny*nx + two_d_index;
            rho_tot += rho_global[three_d_index];
        }

        for(int field_num=0; field_num < num_populations; field_num++){ //Loop over populations first
            int three_d_index = field_num*ny*nx + two_d_index;

            float cur_rho = rho_global[three_d_index];

            float cur_G = G[field_num];
            float cur_omega = omega[field_num];

            float growth = cur_G * cur_rho * (1 - rho_tot);

            for(int jump_id=0; jump_id < 9; jump_id++){
                int four_d_index = jump_id*num_populations*ny*nx + three_d_index;

                float f = f_global[four_d_index];
                float feq = feq_global[four_d_index];
                float cur_w = w[jump_id];

                float relax = f*(1-cur_omega) + cur_omega*feq;

                float new_f = relax + cur_w*growth;

                f_global[four_d_index] = new_f;
            }
        }
    }
}


__kernel void
copy_buffer(__global __read_only float *copy_from,
            __global __write_only float *copy_to,
            const int nx, const int ny, const int num_populations)
{
    //Used to copy the streaming buffer back to the original
    //Assumes a 2d workgroup
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    if ((x < nx) && (y < ny)){
        const int two_d_index = y*nx + x;

        for(int field_num=0; field_num < num_populations; field_num++){
            int three_d_index = field_num*nx*ny + two_d_index;

            for (int jump_id = 0; jump_id < 9; jump_id++){
                int four_d_index = jump_id*num_populations*nx*ny + three_d_index;
                copy_to[four_d_index] = copy_from[four_d_index];
            }
        }
    }
}

__kernel void
move(__global __read_only float *f_global,
     __global __write_only float *f_streamed_global,
     __constant int *cx,
     __constant int *cy,
     const int nx, const int ny, const int num_populations)
{
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

            if ((stream_x >= 0) && (stream_x < nx) && (stream_y >= 0) && (stream_y < ny)){ // Stream
                for(int field_num = 0; field_num < num_populations; field_num++){
                    int slice = jump_id*num_populations*nx*ny + field_num*nx*ny;

                    int old_4d_index = slice + y*nx + x;
                    int new_4d_index = slice + stream_y*nx + stream_x;

                    f_streamed_global[new_4d_index] = f_global[old_4d_index];
                }
            }
        }
    }
}

__kernel void
move_bcs(__global float *f_global,
         __constant float *w,
         const int nx, const int ny)
{
    //TODO: Make this efficient. I recognize there are better ways to do this, perhaps a kernel for each boundary...
    //Input should be a 2d workgroup! Everything is done inplace, no need for a second buffer
    //Must be run after move
    const int x = get_global_id(0);
    const int y = get_global_id(1);

    int two_d_index = y*nx + x;

    bool on_left = (x==0) && (y >= 0)&&(y < ny);
    bool on_right = (x==nx - 1) && (y >= 0)&&(y < ny);
    bool on_top = (y == ny-1) && (x >= 0) && (x< nx);
    bool on_bottom = (y == 0) && (x >= 0) && (x < nx);

    bool on_main_surface = on_left || on_right || on_top || on_bottom;

    if (on_main_surface){

        // You need to read in all f...except f0 actually
        // float f0 = f_global[0*ny*nx + two_d_index];
        float f1 = f_global[1*ny*nx + two_d_index];
        float f2 = f_global[2*ny*nx + two_d_index];
        float f3 = f_global[3*ny*nx + two_d_index];
        float f4 = f_global[4*ny*nx + two_d_index];
        float f5 = f_global[5*ny*nx + two_d_index];
        float f6 = f_global[6*ny*nx + two_d_index];
        float f7 = f_global[7*ny*nx + two_d_index];
        float f8 = f_global[8*ny*nx + two_d_index];

        //Top: No_flux
        if (on_top){
            float rho_to_add = (f2 + f5 + f6)/(w[4] + w[7] + w[8]);
            f_global[7*ny*nx + two_d_index] = w[7] * rho_to_add;
            f_global[4*ny*nx + two_d_index] = w[4] * rho_to_add;
            f_global[8*ny*nx + two_d_index] = w[8] * rho_to_add;
        }

        //Bottom: no flux
        if (on_bottom){
            float rho_to_add = (f4 + f7 + f8)/(w[2] + w[5] + w[6]);
            f_global[2*ny*nx + two_d_index] = w[2] * rho_to_add;
            f_global[5*ny*nx + two_d_index] = w[5] * rho_to_add;
            f_global[6*ny*nx + two_d_index] = w[6] * rho_to_add;
        }

        //Right: no flux
        if (on_right){
            float rho_to_add = (f1 + f5 + f8)/(w[3] + w[6] + w[7]);
            f_global[3*ny*nx + two_d_index] = w[3] * rho_to_add;
            f_global[6*ny*nx + two_d_index] = w[6] * rho_to_add;
            f_global[7*ny*nx + two_d_index] = w[7] * rho_to_add;
        }
        //Left: no flux
        if (on_left){
            float rho_to_add = (f3 + f6 + f7)/(w[1]+w[5]+w[8]);
            f_global[1*ny*nx + two_d_index] = w[1] * rho_to_add;
            f_global[5*ny*nx + two_d_index] = w[5] * rho_to_add;
            f_global[8*ny*nx + two_d_index] = w[8] * rho_to_add;
        }
    }
}