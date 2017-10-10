import numpy as np
import os
os.environ['PYOPENCL_COMPILER_OUTPUT'] = '1'
import pyopencl as cl
import pyopencl.tools
import pyopencl.reduction
import pyopencl.array
import ctypes as ct

# Required to draw obstacles
import skimage as ski
import skimage.draw

float_size = ct.sizeof(ct.c_float)

# Get path to *this* file. Necessary when reading in opencl code.
full_path = os.path.realpath(__file__)
file_dir = os.path.dirname(full_path)
parent_dir = os.path.dirname(file_dir)

##########################
##### D2Q9 parameters ####
##########################
w=np.array([4./9.,1./9.,1./9.,1./9.,1./9.,1./36.,
            1./36.,1./36.,1./36.], order='F', dtype=np.float32)      # weights for directions
cx=np.array([0, 1, 0, -1, 0, 1, -1, -1, 1], order='F', dtype=np.int32)     # direction vector for the x direction
cy=np.array([0, 0, 1, 0, -1, 1, 1, -1, -1], order='F', dtype=np.int32)     # direction vector for the y direction
cs=1./np.sqrt(3)                         # Speed of sound on the lattice

w0 = 4./9.                              # Weight of stationary jumpers
w1 = 1./9.                              # Weight of horizontal and vertical jumpers
w2 = 1./36.                             # Weight of diagonal jumpers

NUM_JUMPERS = 9                         # Number of jumpers for the D2Q9 lattice: 9


def get_divisible_global(global_size, local_size):
    """
    Given a desired global size and a specified local size, return the smallest global
    size that the local size fits into. Required when specifying arbitrary local
    workgroup sizes.

    :param global_size: A tuple of the global size, i.e. (x, y, z)
    :param local_size:  A tuple of the local size, i.e. (lx, ly, lz)
    :return: The smallest global size that the local size fits into.
    """
    new_size = []
    for cur_global, cur_local in zip(global_size, local_size):
        remainder = cur_global % cur_local
        if remainder == 0:
            new_size.append(cur_global)
        else:
            new_size.append(cur_global + cur_local - remainder)
    return tuple(new_size)

class Poisson_Solver(object):
    """
    Simulates pipe flow using the D2Q9 lattice. Generally used to verify that our simulations were working correctly.
    For usage, see the docs folder.
    """

    def __init__(self, nx=None, ny=None, sources=None, delta_t=None, delta_x=None, rho_on_boundary = 0.0,
                 tolerance = 10.**-6., context = None, queue = None,
                 two_d_local_size=(32,32), three_d_local_size=(32,32,1), use_interop=False):

        self.nx = np.int32(nx)
        self.ny = np.int32(ny)

        # Either an opencl buffer or numpy array...to be figured out soon enough
        self.input_sources = sources
        self.scaled_sources = None

        self.use_interop = use_interop

        self.rho_on_boundary = np.float32(rho_on_boundary)
        self.tolerance = np.float32(tolerance)

        # Initialize the lattice to simulate on; see http://wiki.palabos.org/_media/howtos:lbunits.pdf
        self.delta_x = np.float32(delta_x) # How many squares characteristic length is broken into
        self.delta_t = np.float32(delta_t) # How many time iterations until the characteristic time, should be ~ \delta x^2
        self.delta_t = np.float32(self.delta_t)

        self.ulb = self.delta_t/self.delta_x
        print 'u_lb:', self.ulb

        self.lb_D = None
        self.omega = None
        self.set_D_and_omega()

        # Create global & local sizes appropriately
        self.two_d_local_size = two_d_local_size        # The local size to be used for 2-d workgroups
        self.three_d_local_size = three_d_local_size    # The local size to be used for 3-d workgroups

        self.two_d_global_size = get_divisible_global((self.nx, self.ny), self.two_d_local_size)
        self.three_d_global_size = get_divisible_global((self.nx, self.ny, 9), self.three_d_local_size)

        print '2d global:' , self.two_d_global_size
        print '2d local:' , self.two_d_local_size
        print '3d global:' , self.three_d_global_size
        print '3d local:' , self.three_d_local_size

        # Initialize the opencl environment
        self.context = context  # The pyOpenCL context...may pass one in to share buffers
        self.queue = queue       # The queue used to issue commands to the desired device
        self.kernels = None     # Compiled OpenCL kernels
        self.reduction_kernel = None
        self.sum_kernel = None
        self.init_opencl()      # Initializes all items required to run OpenCL code

        # Allocate constants & local memory for opencl
        self.w = None
        self.cx = None
        self.cy = None
        self.host_done_flag = None
        self.gpu_done_flag = None
        self.allocate_constants()

        ## Initialize hydrodynamic variables
        self.rho = None # The simulation's density field
        self.rho_before = None
        self.u = None
        self.v = None
        self.init_hydro() # Create the hydrodynamic fields

        # Intitialize the underlying feq equilibrium field
        feq_host = np.zeros((self.nx, self.ny, NUM_JUMPERS), dtype=np.float32, order='F')
        self.feq = cl.Buffer(self.context, cl.mem_flags.READ_WRITE | cl.mem_flags.COPY_HOST_PTR, hostbuf=feq_host)

        self.update_feq() # Based on the hydrodynamic fields, create feq

        # Now initialize the nonequilibrium f
        f_host=np.zeros((self.nx, self.ny, NUM_JUMPERS), dtype=np.float32, order='F')
        # In order to stream in parallel without communication between workgroups, we need two buffers (as far as the
        # authors can see at least). f will be the usual field of hopping particles and f_temporary will be the field
        # after the particles have streamed.
        self.f = cl.Buffer(self.context, cl.mem_flags.READ_WRITE | cl.mem_flags.COPY_HOST_PTR, hostbuf=f_host)
        self.f_streamed = cl.Buffer(self.context, cl.mem_flags.READ_WRITE | cl.mem_flags.COPY_HOST_PTR, hostbuf=f_host)

        self.init_pop() # Based on feq, create the hopping non-equilibrium fields

        self.num_iterations = 0

    def set_D_and_omega(self):
        self.lb_D = self.delta_t / self.delta_x ** 2 # Should equal about one
        self.lb_D = np.float32(self.lb_D)

        self.omega = (.5 + self.lb_D / cs ** 2) ** -1.  # The relaxation time of the jumpers in the simulation
        self.omega = np.float32(self.omega)
        print 'omega', self.omega
        assert self.omega < 2.

    def update_source(self, new_source):
        """Pass in a new source. Restarts the simulation with the old density."""

        self.input_sources = new_source

        self.scaled_sources = self.input_sources.copy()
        self.scaled_sources *= self.lb_D * self.delta_t
        if type(self.scaled_sources) is pyopencl.array.Array:
            self.scaled_sources.finish()
        self.num_iterations = 0  # Restart the simulation, basically, but keep the last guess of rho.

    def update_negative_gradient(self):
        self.kernels.update_negative_gradient(self.queue, self.two_d_global_size, self.two_d_local_size,
                                          self.rho.data, self.u.data, self.v.data,
                                          self.delta_x,
                                          self.nx, self.ny).wait()

    def init_opencl(self):
        """
        Initializes the base items needed to run OpenCL code.
        """

        # Startup script shamelessly taken from CS205 homework
        if self.context is None:
            platforms = cl.get_platforms()
            print 'The platforms detected are:'
            print '---------------------------'
            for platform in platforms:
                print platform.name, platform.vendor, 'version:', platform.version

            # List devices in each platform
            for platform in platforms:
                print 'The devices detected on platform', platform.name, 'are:'
                print '---------------------------'
                for device in platform.get_devices():
                    print device.name, '[Type:', cl.device_type.to_string(device.type), ']'
                    print 'Maximum clock Frequency:', device.max_clock_frequency, 'MHz'
                    print 'Maximum allocable memory size:', int(device.max_mem_alloc_size / 1e6), 'MB'
                    print 'Maximum work group size', device.max_work_group_size
                    print 'Maximum work item dimensions', device.max_work_item_dimensions
                    print 'Maximum work item size', device.max_work_item_sizes
                    print '---------------------------'

            # Create a context with all the devices
            devices = platforms[0].get_devices()
            if not self.use_interop:
                self.context = cl.Context(devices)
            else:
                self.context = cl.Context(properties=[(cl.context_properties.PLATFORM, platforms[0])]
                                                     + cl.tools.get_gl_sharing_context_properties(),
                                          devices= devices)
            print 'This context is associated with ', len(self.context.devices), 'devices'

            # Create a simple queue
            self.queue = cl.CommandQueue(self.context, self.context.devices[0],
                                         properties=cl.command_queue_properties.PROFILING_ENABLE)
        # Compile our OpenCL code
        self.kernels = cl.Program(self.context, open(parent_dir + '/D2Q9_poisson.cl').read()).build(options='')

        # Create the reduction kernel
        self.reduction_kernel = cl.reduction.ReductionKernel(self.context, np.float32, neutral="0",
                                                             reduce_expr="a+b",
                                                             map_expr="fabs(x[i]-y[i])",
                                                             arguments="__global float *x, \
                                                                        __global float *y")
        self.sum_kernel = cl.reduction.ReductionKernel(self.context, np.float32, neutral="0",
                                                             reduce_expr="a+b",
                                                             map_expr="x[i]",
                                                             arguments="__global float *x")


    def allocate_constants(self):
        """
        Allocates constants and local memory to be used by OpenCL.
        """
        self.w = cl.Buffer(self.context, cl.mem_flags.READ_ONLY | cl.mem_flags.COPY_HOST_PTR, hostbuf=w)
        self.cx = cl.Buffer(self.context, cl.mem_flags.READ_ONLY | cl.mem_flags.COPY_HOST_PTR, hostbuf=cx)
        self.cy = cl.Buffer(self.context, cl.mem_flags.READ_ONLY | cl.mem_flags.COPY_HOST_PTR, hostbuf=cy)

    def init_hydro(self):
        """
        Based on the initial conditions, initialize the hydrodynamic fields, like density and velocity
        """

        nx = self.nx
        ny = self.ny

        # Only density in the innoculated region.
        rho_host = np.zeros((nx, ny), dtype=np.float32, order='F')

        # Transfer arrays to the device...make them arrays as we want to use the reduction kernel of opencl
        self.rho = cl.array.to_device(self.queue, rho_host)
        self.rho_before = cl.array.to_device(self.queue, rho_host)

        self.update_source(self.input_sources)

        # Initialize buffers to store gradient. Same dimensions as rho_host, so we just use that.
        self.u = cl.array.to_device(self.queue, rho_host)
        self.v = cl.array.to_device(self.queue, rho_host)

    def update_feq(self):
        """
        Based on the hydrodynamic fields, create the local equilibrium feq that the jumpers f will relax to.
        Implemented in OpenCL.
        """
        self.kernels.update_feq(self.queue, self.two_d_global_size, self.two_d_local_size,
                                self.feq, self.rho.data, self.w,
                                self.nx, self.ny).wait()

    def init_pop(self, amplitude=10.**-5.):
        """Based on feq, create the initial population of jumpers."""

        nx = self.nx
        ny = self.ny

        # For simplicity, copy feq to the local host, where you can make a copy. There is probably a better way to do this.
        f = np.zeros((nx, ny, NUM_JUMPERS), dtype=np.float32, order='F')
        cl.enqueue_copy(self.queue, f, self.feq, is_blocking=True)

        # We now slightly perturb f
        amplitude = amplitude
        perturb = (1. + amplitude*np.random.randn(nx, ny, NUM_JUMPERS))
        f *= perturb

        # Now send f to the GPU
        self.f = cl.Buffer(self.context, cl.mem_flags.READ_WRITE | cl.mem_flags.COPY_HOST_PTR, hostbuf=f)

        # f_temporary will be the buffer that f moves into in parallel.
        self.f_streamed = cl.Buffer(self.context, cl.mem_flags.READ_WRITE | cl.mem_flags.COPY_HOST_PTR, hostbuf=f)

    def move_bcs(self):
        """
        Enforce boundary conditions and move the jumpers on the boundaries. Generally extremely painful.
        Implemented in OpenCL.
        """
        self.kernels.move_bcs(self.queue, self.three_d_global_size, self.three_d_local_size,
                          self.f, self.rho_on_boundary, self.w,
                          self.nx, self.ny).wait()

    def move(self):
        """
        Move all other jumpers than those on the boundary. Implemented in OpenCL. Consists of two steps:
        streaming f into a new buffer, and then copying that new buffer onto f. We could not think of a way to stream
        in parallel without copying the temporary buffer back onto f.
        """
        self.kernels.move(self.queue, self.three_d_global_size, self.three_d_local_size,
                                self.f, self.f_streamed,
                                self.cx, self.cy,
                                self.nx, self.ny).wait()

        # Copy the streamed buffer into f so that it is correctly updated.
        self.kernels.copy_buffer(self.queue, self.three_d_global_size, self.three_d_local_size,
                                self.f_streamed, self.f,
                                self.nx, self.ny).wait()

    def update_hydro(self):
        """
        Based on the new positions of the jumpers, update the hydrodynamic variables. Implemented in OpenCL.
        """
        self.kernels.update_hydro(self.queue, self.two_d_global_size, self.two_d_local_size,
                                self.f, self.rho.data,
                                self.nx, self.ny).wait()

    def collide_particles(self):
        """
        Relax the nonequilibrium f fields towards their equilibrium feq. Depends on omega. Implemented in OpenCL.
        """
        self.kernels.collide_particles(self.queue, self.two_d_global_size, self.two_d_local_size,
                                self.f, self.feq, self.scaled_sources.data, self.omega, self.w,
                                self.delta_t, self.lb_D,
                                self.nx, self.ny).wait()

    def run(self, num_iterations):
        """
        Run the simulation for num_iterations. Be aware that the same number of iterations does not correspond
        to the same non-dimensional time passing, as delta_t, the time discretization, will change depending on
        your resolution.

        :param num_iterations: The number of iterations to run
        """

        for cur_iteration in range(num_iterations):

            # Copy the current rho onto the previous rho
            cl.enqueue_copy(self.queue, self.rho_before.data, self.rho.data)

            self.move() # Move all jumpers
            self.move_bcs() # Our BC's rely on streaming before applying the BC, actually

            self.update_hydro() # Update the hydrodynamic variables
            self.update_feq() # Update the equilibrium fields

            self.collide_particles() # Relax the nonequilibrium fields.

            self.num_iterations += 1

            if self.num_iterations != 1:
                # Check that your simulation has not converged
                weight = (1./(self.nx*self.ny))
                average_difference = weight*self.reduction_kernel(self.rho_before, self.rho).get()
                rho_av = weight * self.sum_kernel(self.rho_before).get()

                if (average_difference/rho_av) < self.tolerance:
                    print 'Done in' , self.num_iterations , 'iterations'
                    print 'Updating u and v...'
                    self.update_negative_gradient()
                    break

    def get_fields(self):
        """
        :return: Returns a dictionary of all fields. Transfers data from the GPU to the CPU.
        """
        f = np.zeros((self.nx, self.ny, NUM_JUMPERS), dtype=np.float32, order='F')
        cl.enqueue_copy(self.queue, f, self.f, is_blocking=True)

        feq = np.zeros((self.nx, self.ny, NUM_JUMPERS), dtype=np.float32, order='F')
        cl.enqueue_copy(self.queue, feq, self.feq, is_blocking=True)

        rho = np.zeros((self.nx, self.ny), dtype=np.float32, order='F')
        cl.enqueue_copy(self.queue, rho, self.rho.data, is_blocking=True)

        results={}
        results['f'] = f
        results['rho'] = rho
        results['feq'] = feq
        return results