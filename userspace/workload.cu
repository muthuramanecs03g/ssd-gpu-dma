#include <cuda.h>
#include "memory/types.h"
#include "memory/gpu.h"
#include "memory/ram.h"
#include "nvm/types.h"
#include "nvm/queue.h"
#include "nvm/command.h"
#include "nvm/util.h"
#include "nvm/ctrl.h"
#include <cstdio>
#include <cstddef>
#include <cstring>
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>



__host__ __device__
static int prepare_read_cmd(nvm_queue_t sq, uint32_t ns_id, uint32_t blk_size, memory_t* buffer, uint64_t start_lba, uint16_t n_blks)
{
    struct command* cmd = sq_enqueue(sq);
    if (cmd == NULL)
    {
        return EAGAIN;
    }

    size_t len = (n_blks * blk_size) / buffer->page_size;

    cmd_header(cmd, NVM_READ, ns_id);
    cmd_data_ptr(cmd, NULL, buffer, _MIN(buffer->n_addrs, len));

    cmd->dword[10] = (uint32_t) start_lba;
    cmd->dword[11] = (uint32_t) (start_lba >> 32);

    cmd->dword[12] = (0x00 << 31) | (0x00 << 30) | (0x00 << 26) | n_blks;

    cmd->dword[13] = 0;
    cmd->dword[14] = 0;
    cmd->dword[15] = 0;

    return 0;
}


__global__ void do_work(memory_t* buffer, nvm_queue_t sq, nvm_queue_t cq, uint32_t* result)
{
    prepare_read_cmd(sq, 1, 512, buffer, 0, 1);
    sq_submit(sq);

    //while (cq_poll(cq) == NULL);

    //*result = *((uint32_t*) buffer->virt_addr);
}


static int create_queues(int ioctl_fd, nvm_controller_t ctrl, int dev, nvm_queue_t* cq, nvm_queue_t* sq)
{
    int err;

    err = nvm_prepare_queues(ctrl, cq, sq);
    if (err != 0)
    {
        fprintf(stderr, "Failed to prepare queue handles\n");
        return err;
    }

    err = get_gpu_page(ioctl_fd, dev, &((*cq)->page));
    if (err != 0)
    {
        fprintf(stderr, "Failed to allocate queue memory\n");
        return ENOMEM;
    }
    cudaMemset((*cq)->page.virt_addr, 0, (*cq)->page.page_size);

    err = get_gpu_page(ioctl_fd, dev, &((*sq)->page));
    if (err != 0)
    {
        fprintf(stderr, "Failed to allocate queue memory\n");
        return ENOMEM;
    }
    cudaMemset((*sq)->page.virt_addr, 0, (*sq)->page.page_size);

    err = nvm_commit_queues(ctrl);
    if (err != 0)
    {
        fprintf(stderr, "Failed to commit prepared queues\n");
        return err;
    }

    return 0;
}


extern "C" __host__
int cuda_workload(int ioctl_fd, nvm_controller_t ctrl, int dev)
{
    cudaError_t err = cudaSetDevice(dev);
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to set CUDA device: %s\n", cudaGetErrorString(err));
        return EBADF;
    }

    nvm_queue_t host_sq, host_cq;
    int status = create_queues(ioctl_fd, ctrl, dev, &host_cq, &host_sq);
    if (status != 0)
    {
        fprintf(stderr, "Failed to create queues: %s\n", strerror(status));
        return status;
    }

    nvm_queue_t dev_sq, dev_cq;

    err = cudaMalloc(&dev_sq, sizeof(struct nvm_queue));
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to allocate device memory: %s\n", cudaGetErrorString(err));
        return ENOMEM;
    }

    err = cudaMalloc(&dev_cq, sizeof(struct nvm_queue));
    if (err != cudaSuccess)
    {
        cudaFree(dev_sq);
        fprintf(stderr, "Failed to allocate device memory: %s\n", cudaGetErrorString(err));
        return ENOMEM;
    }

    memory_t* host_buffer = get_gpu_buffer(ioctl_fd, dev, sizeof(uint32_t));
    if (host_buffer == NULL)
    {
        cudaFree(dev_sq);
        cudaFree(dev_cq);
        fprintf(stderr, "Failed to allocate buffer\n");
        return ENOMEM;
    }

    memory_t* dev_buffer;
    err = cudaMalloc(&dev_buffer, sizeof(memory_t));
    if (err != cudaSuccess)
    {
        put_gpu_buffer(ioctl_fd, host_buffer);
        cudaFree(dev_sq);
        cudaFree(dev_cq);
        fprintf(stderr, "Failed to allocate device memory: %s\n", cudaGetErrorString(err));
        return ENOMEM;
    }

    cudaHostRegister((void*) host_sq->db, sizeof(uint32_t), cudaHostRegisterIoMemory);
    
    void* db;
    cudaHostGetDevicePointer(&db, (void*) host_sq->db, 0);
    host_sq->db = (volatile uint32_t*) db;

    cudaMemcpy(dev_sq, host_sq, sizeof(struct nvm_queue), cudaMemcpyHostToDevice);
    cudaMemcpy(dev_cq, host_cq, sizeof(struct nvm_queue), cudaMemcpyHostToDevice);
    cudaMemcpy(dev_buffer, host_buffer, sizeof(memory_t), cudaMemcpyHostToDevice);

    uint32_t* value;
    cudaMalloc(&value, sizeof(uint32_t));

    do_work<<<1, 1>>>(dev_buffer, dev_sq, dev_cq, value);

    //uint32_t result = 0xcafebabe;
    //cudaMemcpy(&result, value, sizeof(uint32_t), cudaMemcpyDeviceToHost);

    usleep(50000);

    fprintf(stderr, "%x\n", *((uint32_t*) host_buffer->virt_addr));
    //fprintf(stderr, "%x\n", result);

    cudaFree(value);
    cudaFree(dev_buffer);
    put_gpu_buffer(ioctl_fd, host_buffer);
    cudaFree(dev_sq);
    cudaFree(dev_cq);
    return 0;
}



//__host__ __device__
//static int prepare_write(nvm_queue_t sq, uint32_t ns_id, page_t* buf, uint64_t start_lba, uint16_t n_blks)
//{
//    struct command* cmd = sq_enqueue(sq);
//    if (cmd == NULL)
//    {
//        return EAGAIN;
//    }
//
//    // Set command header
//    cmd->dword[0] |= (0x00 << 14) | (0x00 << 8) | WRITE;
//
//    // Specify namespace
//    cmd->dword[1] = ns_id;
//
//    cmd->dword[4] = 0;
//    cmd->dword[5] = 0;
//
//    uint64_t phys_addr = buf->phys_addr;
//    cmd->dword[6] = (uint32_t) phys_addr;
//    cmd->dword[7] = (uint32_t) (phys_addr >> 32);
//    cmd->dword[8] = 0;
//    cmd->dword[9] = 0;
//
//    cmd->dword[10] = (uint32_t) start_lba;
//    cmd->dword[11] = (uint32_t) (start_lba >> 32);
//
//    cmd->dword[12] = n_blks;
//    cmd->dword[13] = 0;
//    cmd->dword[14] = 0;
//    cmd->dword[15] = 0;
//
//    return 0;
//}