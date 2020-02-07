/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "HugeCTR/include/data_parser.hpp"
#include "HugeCTR/include/data_reader.hpp"
#include "HugeCTR/include/embeddings/distributed_slot_sparse_embedding_hash.hpp"
#include "HugeCTR/include/embeddings/localized_slot_sparse_embedding_hash.hpp"
#include "utest/embedding/sparse_embedding_hash_cpu.hpp"
#include "utest/embedding/embedding_test_utils.hpp"
#include "utest/test_utils.h"
#include "gtest/gtest.h"
#include "nvToolsExt.h"
#include <sys/time.h>
#include <fstream>
#include <functional>
#include <nccl.h>

using namespace HugeCTR;
using namespace embedding_test;

namespace {

//---------------------------------------------------------------------------------------
// global params for all testing 
const std::vector<int> device_list = {0,1,2,3};
//const std::vector<int> device_list = {0};
const int batch_num = 2;  // can not more than 32
const int batchsize = 4096;
const long long num_records = batchsize * batch_num;
const int slot_num = 8; 
const int max_nnz_per_slot = 10;
const int max_feature_num = max_nnz_per_slot * slot_num;  // max_feature_num in a sample
const long long vocabulary_size = 55000;
const int embedding_vec_size = 64;
const int combiner = 0;   // 0-sum, 1-mean
const int optimizer = 0;  // 0-adam, 1-momentum_sgd, 2-nesterov
const float lr = 0.01;
const long long label_dim = 1;
const long long dense_dim = 0;
typedef long long T;

// In order to not allocate the total size of hash table on each GPU, the users need to set the
// size of max_vocabulary_size_per_gpu, which should be more than vocabulary_size/gpu_count,
// eg: 1.25x of that.
const float load_factor = 0.75;  // CAUSION: this is a very important param for performance

const int num_chunks = 1; // must be 1 for CPU and GPU results comparation 
const int num_threads = 1; // must be 1 for CPU and GPU results comparation 
const int num_files = 1;
const Check_t CHK = Check_t::Sum; // Check_t::Sum
const std::string file_list_name("sample_file_list.txt");
const std::string prefix("./data_reader_test_data/temp_dataset_");
const std::string plan_file("./bin/all2all_plan.json");

const char *hash_table_file_name = "localized_hash_table.bin";
bool init_hash_table = true;  // true: init hash_table and upload_to_device
                              // false: don't init hash_table or upload_to_device, just use an
                              //        empty hash_table to train

//-----------------------------------------------------------------------------------------

#if 0
TEST(localized_sparse_embedding_hash_test, reorder) {
  int local_gpu_count = 4; // 4,2 pass 
  int embedding_vec_size = 4;
  int batch_size = 16; // 8,16 pass 
  int samples_per_gpu = batch_size / local_gpu_count;
  int slot_num = 10; // 8,10 pass 
  int slots_per_sample = (slot_num + local_gpu_count - 1) / local_gpu_count; 
  int size_per_gpu = batch_size * slots_per_sample * embedding_vec_size;

  float * h_src, * d_src, * h_dst, * d_dst;
  cudaMallocHost(&h_src, size_per_gpu*sizeof(float));
  cudaMallocHost(&h_dst, size_per_gpu*sizeof(float));
  cudaMalloc(&d_src, size_per_gpu*sizeof(float));
  cudaMalloc(&d_dst, size_per_gpu*sizeof(float));

  int stride = samples_per_gpu * slots_per_sample * embedding_vec_size;
  for(int i = 0; i < samples_per_gpu; i++) {
    int offset = i * slots_per_sample * embedding_vec_size;
    for(int j = 0; j < slot_num; j++) {
      int addr = offset + (j/local_gpu_count) * embedding_vec_size + (j%local_gpu_count) * stride;
      //printf("sample_id=%d, slot_id=%d, addr=%d\n", i, j, addr);
      for(int k = 0; k < embedding_vec_size; k++) {
        h_src[addr+k] = (float)j;
      }
    }
  }

  std::cout << "original dataset:" << std::endl;
  for(int i = 0; i < batch_size; i++) {
    for(int j = 0; j < slots_per_sample; j++) {
      for(int k = 0; k < embedding_vec_size; k++) {
        int addr = i*slots_per_sample*embedding_vec_size+j*embedding_vec_size+k;
        //std::cout << "addr[" << addr << "]=" << h_src[addr] << ", ";
        std::cout << h_src[addr] << ", ";
      }
    }
    std::cout << std::endl;
  }
  std::cout << std::endl;

  dim3 blockSize(embedding_vec_size, 1, 1);
  dim3 gridSize(batch_size/local_gpu_count, 1, 1);

  cudaMemcpy(d_src, h_src, size_per_gpu * sizeof(float), cudaMemcpyHostToDevice);

  reorder_kernel<float><<<gridSize, blockSize>>>(batch_size,
                                                  slot_num,
                                                  embedding_vec_size,
                                                  local_gpu_count,
                                                  d_src,
                                                  d_dst);

  cudaMemcpy(h_dst, d_dst, size_per_gpu * sizeof(float), cudaMemcpyDeviceToHost);

  std::cout << "reodered dataset:" << std::endl;
  for(int i = 0; i < samples_per_gpu; i++) {
    std::cout << "sample " << i << ":" << std::endl;
    for(int j = 0; j < slot_num; j++) {
      for(int k = 0; k < embedding_vec_size; k++) {
        int addr = i*slot_num*embedding_vec_size+j*embedding_vec_size+k;
        std::cout << h_dst[addr] << ", ";
      }
    }
    std::cout << std::endl;
  }
  std::cout << std::endl;         

  // check results 
  bool results = true;
  for(int i = 0; i < samples_per_gpu; i++) {
    for(int j = 0; j < slot_num; j++) {
      for(int k = 0; k < embedding_vec_size; k++) {
        int addr = i*slot_num*embedding_vec_size+j*embedding_vec_size+k;
        if(!compare_element(h_dst[addr], float(j))) {
          results = false;
          j = slot_num;
          i = samples_per_gpu;
          break;
        }
      }
    }
  }

  ASSERT_EQ(results, true);
  
  cudaFreeHost(h_src);
  cudaFreeHost(h_dst);
  cudaFree(d_src);
  cudaFree(d_dst);
}
#endif 

#if 0
TEST(localized_sparse_embedding_hash_test, all2all_reorder_single_node) {
  std::vector<int> device_list = {0,1,2,3}; // 4,8 gpus pass
  int local_gpu_count = device_list.size();
  int embedding_vec_size = 4;
  int batch_size = 8; // 8,16 pass
  int samples_per_gpu = batch_size / local_gpu_count;
  int slot_num = 10;  // 8,10 pass
  int slots_per_sample = (slot_num + local_gpu_count - 1) / local_gpu_count; 
  int size_per_gpu = batch_size * slots_per_sample * embedding_vec_size;

  std::vector<std::vector<int>> vvgpu;
  vvgpu.push_back(device_list);
  std::shared_ptr<DeviceMap> device_map(new DeviceMap(vvgpu, 0));
  std::shared_ptr<GPUResourceGroup> gpu_resource_group(new GPUResourceGroup(device_map));
  CudaDeviceContext context((*gpu_resource_group)[0]->get_device_id());
  
  SparseEmbeddingHashFunctors functors;

  std::vector<float *> h_src(local_gpu_count);
  std::vector<float *> h_mid(local_gpu_count);
  std::vector<float *> h_dst(local_gpu_count);
  for(int id = 0; id < local_gpu_count; id++) {
    cudaMallocHost(&h_src[id], size_per_gpu*sizeof(float));
    cudaMallocHost(&h_mid[id], size_per_gpu*sizeof(float));
    cudaMallocHost(&h_dst[id], size_per_gpu*sizeof(float));
  }

  Tensors<float> d_src;
  Tensors<float> d_mid;
  Tensors<float> d_dst;
  GeneralBuffers<float> buf;
  for (int i = 0; i < local_gpu_count; i++) {
    int cur_device = (*gpu_resource_group)[i]->get_device_id();
    context.set_device(cur_device);
    std::cout << "GPU " << cur_device << std::endl;

    buf.emplace_back(new GeneralBuffer<float>());

    std::vector<int> dims = {batch_size, slots_per_sample, embedding_vec_size};
    std::cout << "\tdims[" << dims[0] << " " << dims[1] << " " << dims[2] << "]" << std::endl;

    d_src.emplace_back(new Tensor<float>(dims, buf.back(), TensorFormat_t::HSW));
    d_mid.emplace_back(new Tensor<float>(dims, buf.back(), TensorFormat_t::HSW));
    d_dst.emplace_back(new Tensor<float>(dims, buf.back(), TensorFormat_t::HSW));

    buf.back()->init(cur_device);
    std::cout << "\tbuf size:" << buf.back()->get_size() << std::endl;
  }

  // init src
  for(int id = 0; id < local_gpu_count; id++) {
    for(int sample_id = 0; sample_id < batch_size; sample_id++) {
      for(int slot_id = 0; slot_id < slots_per_sample; slot_id++) {
        int index = sample_id * slots_per_sample + slot_id;
        int value = id + slot_id * local_gpu_count;
        if(value < slot_num) {
          for(int k = 0; k < embedding_vec_size; k++) {
            h_src[id][index * embedding_vec_size + k] = value;
          }
        }
      }
    }
  }

  std::cout << "original dataset:" << std::endl;
  for(int id = 0; id < local_gpu_count; id++) {
    std::cout << "gpu " << id << ": " << std::endl;
    for(int sample_id = 0; sample_id < batch_size; sample_id++) {
      std::cout << "\tsample " << sample_id << ": ";
      for(int slot_id = 0; slot_id < slots_per_sample; slot_id++) {
        int index = sample_id * slots_per_sample + slot_id;
        for(int k = 0; k < embedding_vec_size; k++) {
          std::cout << h_src[id][index * embedding_vec_size + k] << ", ";
        }
      }
      std::cout << std::endl;
    }
    std::cout << std::endl;
  }

  // memcpy from CPU to GPU
  std::cout << "memcpy from CPU to GPU:" << std::endl;
  for(int id = 0; id < local_gpu_count; id++) {
    int cur_device = (*gpu_resource_group)[id]->get_device_id();
    context.set_device(cur_device);

    cudaMemcpyAsync(d_src[id]->get_ptr(), h_src[id], size_per_gpu * sizeof(float), \
      cudaMemcpyHostToDevice, (*gpu_resource_group)[id]->get_stream());
  }
  functors.sync_all_gpus(gpu_resource_group, context);

  // all2all 
  using comm_handler_traits = FasterGossipComm::FasterGossipCommAll2AllTraits<float>;
  using comm_handler = FasterGossipComm::FasterGossipComm<float, comm_handler_traits>;
  std::unique_ptr<comm_handler> all2all;
  const std::string plan_file = "./bin/all2all_plan.json";
  const size_t element_per_send = samples_per_gpu * slots_per_sample * embedding_vec_size;
  std::cout << "all2all init" << std::endl;
  functors.all2all_init(all2all, plan_file, element_per_send, d_src, d_mid, gpu_resource_group);
  std::cout << "all2all async" << std::endl;
  functors.all2all_async(all2all);
  std::cout << "sync" << std::endl;
  functors.sync_all_gpus(gpu_resource_group, context);

  // check results of all2all
  for(int id = 0; id < local_gpu_count; id++) {
    int cur_device = (*gpu_resource_group)[id]->get_device_id();
    context.set_device(cur_device);

    cudaMemcpyAsync(h_mid[id], d_mid[id]->get_ptr(), size_per_gpu * sizeof(float), \
      cudaMemcpyDeviceToHost, (*gpu_resource_group)[id]->get_stream());
  }
  functors.sync_all_gpus(gpu_resource_group, context);

  std::cout << "all2all dataset:" << std::endl;
  for(int id = 0; id < local_gpu_count; id++) {
    std::cout << "gpu " << id << ": " << std::endl;
    for(int sample_id = 0; sample_id < batch_size; sample_id++) {
      std::cout << "\t";
      for(int slot_id = 0; slot_id < slots_per_sample; slot_id++) {
        int index = sample_id * slots_per_sample + slot_id;
        for(int k = 0; k < embedding_vec_size; k++) {
          std::cout << h_mid[id][index * embedding_vec_size + k] << ", ";
        }
      }
      std::cout << std::endl;
    }
    std::cout << std::endl;
  }   

  // reorder
  std::cout << "reorder" << std::endl;
  dim3 blockSize(embedding_vec_size, 1, 1);
  dim3 gridSize(batch_size/local_gpu_count, 1, 1);
  for(int id = 0; id < local_gpu_count; id++) {
    context.set_device((*gpu_resource_group)[id]->get_device_id());
    reorder_kernel<float><<<gridSize, blockSize, 0, (*gpu_resource_group)[id]->get_stream()>>>(batch_size,
                                                    slot_num,
                                                    embedding_vec_size,
                                                    local_gpu_count,
                                                    d_mid[id]->get_ptr(),
                                                    d_dst[id]->get_ptr());
  }

  // memcpy from GPU to CPU
  std::cout << "memcpy from GPU to CPU" << std::endl;
  for(int id = 0; id < local_gpu_count; id++) {
    int cur_device = (*gpu_resource_group)[id]->get_device_id();
    context.set_device(cur_device);

    cudaMemcpyAsync(h_dst[id], d_dst[id]->get_ptr(), size_per_gpu * sizeof(float), \
      cudaMemcpyDeviceToHost, (*gpu_resource_group)[id]->get_stream());
  }
  functors.sync_all_gpus(gpu_resource_group, context);

  std::cout << "reodered dataset:" << std::endl;
  for(int id = 0; id < local_gpu_count; id++) {
    std::cout << "gpu " << id << ": " << std::endl;
    for(int sample_id = 0; sample_id < samples_per_gpu; sample_id++) {
      std::cout << "\tsample " << id*samples_per_gpu+sample_id << ": ";
      for(int slot_id = 0; slot_id < slot_num; slot_id++) {
        int index = sample_id * slot_num + slot_id;
        for(int k = 0; k < embedding_vec_size; k++) {
          std::cout << h_dst[id][index * embedding_vec_size + k] << ", ";
        }
      }
      std::cout << std::endl;
    }
    std::cout << std::endl;
  }     

  // check results 
  bool results = true;
  for(int id = 0; id < local_gpu_count; id++) {
    for(int sample_id = 0; sample_id < samples_per_gpu; sample_id++) {
      for(int slot_id = 0; slot_id < slot_num; slot_id++) {
        int index = sample_id * slot_num + slot_id;
        for(int k = 0; k < embedding_vec_size; k++) {
          if(!compare_element(h_dst[id][index * embedding_vec_size + k], float(slot_id))) {
            results = false;
            id = local_gpu_count;
            sample_id = samples_per_gpu;
            slot_id = slot_num;
            break;
          }
        }
      }
    }
  } 

  ASSERT_EQ(results, true);
  
  for(int id = 0; id < local_gpu_count; id++) {
    cudaFreeHost(h_src[id]);
    cudaFreeHost(h_mid[id]);
    cudaFreeHost(h_dst[id]);
  }
}
#endif 

#if 0
// localized_sparse_embedding_hash upload_params() and download_params() testing
TEST(localized_sparse_embedding_hash_test, upload_and_download_params) {

  const SparseEmbeddingHashParams embedding_params = {
      batchsize, vocabulary_size, load_factor, embedding_vec_size, 
      max_feature_num, slot_num, 0, 0};

  int numprocs = 1, pid = 0;
  std::vector<std::vector<int>> vvgpu;
#ifdef ENABLE_MPI
  test::mpi_init();
  MPI_Comm_rank(MPI_COMM_WORLD, &pid);
  MPI_Comm_size(MPI_COMM_WORLD, &numprocs);
#endif
  for (int i = 0; i < numprocs; i++) {
    vvgpu.push_back(device_list);
  }
  std::shared_ptr<DeviceMap> device_map(new DeviceMap(vvgpu, pid));
  std::shared_ptr<GPUResourceGroup> gpu_resource_group(new GPUResourceGroup(device_map));

#if 1
  // re-generate the dataset files 
  std::ifstream file(file_list_name);
  if(file.good()) {
    std::remove(file_list_name.c_str());
  }
#endif 
  // data generation: key's corresponding slot_id=(key%slot_num)
  HugeCTR::data_generation_for_localized_test<T, CHK>(file_list_name, prefix, num_files, num_records, slot_num,
      vocabulary_size, label_dim, dense_dim, max_nnz_per_slot);

  //setup a data reader
  const DataReaderSparseParam param = {DataReaderSparse_t::Localized, max_nnz_per_slot*slot_num, slot_num};
  std::vector<DataReaderSparseParam> params;
  params.push_back(param);
  DataReader<T> * data_reader = new DataReader<T>(file_list_name, batchsize, label_dim, dense_dim, CHK, params, 
                            gpu_resource_group, num_chunks, num_threads);

  // define object
  Embedding<T>* embedding = new LocalizedSlotSparseEmbeddingHash<T>(\
      data_reader->get_row_offsets_tensors(), data_reader->get_value_tensors(), \
      embedding_params, plan_file, gpu_resource_group);

  // init hash table file
  const std::string hash_table_upload("localized_hash_table_upload.bin");
  const std::string hash_table_download("localized_hash_table_download.bin");       

  std::ofstream weight_stream(hash_table_upload);
  if(!weight_stream.is_open()) {
    ERROR_MESSAGE_("Error: file not open for writing");
  }
  //UnifiedDataSimulator<T> ldata_sim(0, vocabulary_size-1); // for key 
  UnifiedDataSimulator<T> ldata_sim(0, slot_num-1); // for slot_id
  UnifiedDataSimulator<float> fdata_sim(0, vocabulary_size-1); // for value
  T * p_key = (T *)malloc(vocabulary_size * sizeof(T));
  UnorderedKeyGenerator<T> unorderedKey;
  unorderedKey.fill_unique(p_key, vocabulary_size);
  // key + slot_id + value
  for(int i = 0; i < vocabulary_size; i++) {
  	//T key = (T)i;
  	//T key = ldata_sim.get_num(); // CAUSION: can not get correct results when testing by the case with duplicated keys
  	//weight_stream.write((char *)&key, sizeof(T));
    weight_stream.write((char *)&p_key[i], sizeof(T));
    T slot_id = ldata_sim.get_num();
    weight_stream.write((char *)&slot_id, sizeof(T));
    //float val = (float)i;
  	float val = fdata_sim.get_num();
    for(int j = 0; j < embedding_vec_size; j++) {
      weight_stream.write((char *)&val, sizeof(float));
    }

    // std::cout << "i=" << i << ":key=" << p_key[i] << " slot_id=" << slot_id << " val=" << val << std::endl;
  }
  weight_stream.close();
  free(p_key);

  // upload data from host to device
  std::ifstream i_weight_stream(hash_table_upload);
  printf("start updaload_params_to_device()\n");
  embedding->upload_params_to_device(i_weight_stream);
  i_weight_stream.close();

  // download data from device to host
  std::ofstream o_weight_stream(hash_table_download);
  printf("start download_params_to_host()\n");
  embedding->download_params_to_host(o_weight_stream);
  o_weight_stream.close();

  // comapre the read file with the written file
  typedef struct TypeHashValue_{
  	float data[embedding_vec_size];
  } TypeHashValue;

  printf("start compare_localized_hash_table_files()\n");
  bool rtn = compare_localized_hash_table_files<T, T, TypeHashValue>(hash_table_upload, hash_table_download);
  ASSERT_EQ(true, rtn);
}
#endif 

#if 1
// localized_sparse_embedding_hash correctness testing: forward->backward->update_params
TEST(localized_sparse_embedding_hash_test, training_correctness) {

  OptHyperParams hyper_params;
  hyper_params.adam.beta1 = 0.9f;
  hyper_params.adam.beta2 = 0.999f;
  hyper_params.adam.epsilon = 1e-8f;
  hyper_params.momentum.factor = 0.9f;
  hyper_params.nesterov.mu = 0.9f;

  const OptParams opt_params = {optimizer, lr, hyper_params};

  const SparseEmbeddingHashParams embedding_params = {
      batchsize, vocabulary_size, load_factor, embedding_vec_size, 
      max_feature_num, slot_num, combiner, opt_params};

  int numprocs = 1, pid = 0;
  std::vector<std::vector<int>> vvgpu;
#ifdef ENABLE_MPI
  test::mpi_init();
  MPI_Comm_rank(MPI_COMM_WORLD, &pid);
  MPI_Comm_size(MPI_COMM_WORLD, &numprocs);
#endif
  for (int i = 0; i < numprocs; i++) {
    vvgpu.push_back(device_list);
  }
  std::shared_ptr<DeviceMap> device_map(new DeviceMap(vvgpu, pid));
  std::shared_ptr<GPUResourceGroup> gpu_resource_group(new GPUResourceGroup(device_map));

#if 1
  // re-generate the dataset files 
  std::ifstream file(file_list_name);
  if(file.good()) {
    std::remove(file_list_name.c_str());
  }
#endif
  // data generation: key's corresponding slot_id=(key%slot_num)
  HugeCTR::data_generation_for_localized_test<T, CHK>(file_list_name, prefix, num_files, num_records, slot_num,
      vocabulary_size, label_dim, dense_dim, max_nnz_per_slot);

  //setup a data reader
  const DataReaderSparseParam param = {DataReaderSparse_t::Localized, max_nnz_per_slot*slot_num, slot_num};
  std::vector<DataReaderSparseParam> params;
  params.push_back(param);
  DataReader<T> * data_reader = new DataReader<T>(file_list_name, batchsize, label_dim, dense_dim, CHK, params, 
                            gpu_resource_group, num_chunks, num_threads);

  Embedding<T> *embedding = new LocalizedSlotSparseEmbeddingHash<T>(data_reader->get_row_offsets_tensors(),
                                                       data_reader->get_value_tensors(),
                                                       embedding_params, plan_file, gpu_resource_group);

  if (init_hash_table) {
    // init hash table file: <key, solt_id, value>
    std::ofstream weight_stream(hash_table_file_name);
    if (!weight_stream.is_open()) {
      ERROR_MESSAGE_("Error: file not open for writing");
    }
    //UnifiedDataSimulator<T> ldata_sim(0, slot_num-1); // for slot_id
    UnifiedDataSimulator<float> fdata_sim(-0.1f, 0.1f); // for value
    for (long long i = 0; i < vocabulary_size; i++) {
      T key = (T)i;
      // T key = ldata_sim.get_num();
      // CAUSION: can not set random keys here, because we need to ensure that:
      // 1) we can find keys in the data file from this hash table
      // 2) there are no repeated keys
      weight_stream.write((char *)&key, sizeof(T));
      //T slot_id = ldata_sim.get_num();
      T slot_id = key%slot_num; // CAUSION: need to dedicate the slot_id for each key for correctness verification
      weight_stream.write((char *)&slot_id, sizeof(T));
      // float val = (float)i;
      // float val = 1.0f;
      float val = fdata_sim.get_num();
      for (int j = 0; j < embedding_vec_size; j++) {
        weight_stream.write((char *)&val, sizeof(float));
      }
    }
    weight_stream.close();

    // upload hash table to device
    std::ifstream i_weight_stream(hash_table_file_name);
    embedding->upload_params_to_device(i_weight_stream);
    i_weight_stream.close();
  }

  // for SparseEmbeddingCpu
  SparseEmbeddingHashCpu<T> *embedding_cpu = new SparseEmbeddingHashCpu<T>(
    batchsize, max_feature_num, vocabulary_size, embedding_vec_size, slot_num, 
    label_dim, dense_dim, CHK, num_records, combiner, optimizer, lr, 
    file_list_name, hash_table_file_name, SparseEmbedding_t::Localized);

  // for results check
  float *embedding_feature_from_gpu =
      (float *)malloc(batchsize * slot_num * embedding_vec_size * sizeof(float));
  float *embedding_feature_from_cpu = embedding_cpu->get_forward_results();
  float *wgrad_from_gpu = (float *)malloc(batchsize * slot_num * embedding_vec_size * sizeof(float));
  float *wgrad_from_cpu = embedding_cpu->get_backward_results();
  T *hash_table_key_from_gpu = (T *)malloc(vocabulary_size * sizeof(T));
  float *hash_table_value_from_gpu =
      (float *)malloc(vocabulary_size * (long long)embedding_vec_size * sizeof(float));
  T *hash_table_key_from_cpu = embedding_cpu->get_hash_table_key_ptr();
  float *hash_table_value_from_cpu = embedding_cpu->get_hash_table_value_ptr();

  typedef struct TypeHashValue_ {
    float data[embedding_vec_size];
  } TypeHashValue;

  for (int i = 0; i < batch_num; i++) {
    printf("Round %d start:\n", i);

    // call read a batch
    printf("data_reader->read_a_batch_to_device()\n");
    data_reader->read_a_batch_to_device();

    // GPU forward
    printf("embedding->forward()\n");
    embedding->forward();

    // CPU forward
    printf("embedding_cpu->forward()\n");
    embedding_cpu->forward();

    // check the result of forward
    printf("embedding->get_forward_results()\n");
    embedding->get_forward_results(embedding_feature_from_gpu);  // memcpy from GPU to CPU

    // for(int l=0; l<batchsize; l++) {
    //   for(int j=0; j<slot_num; j++) {
    //     for(int k=0; k<embedding_vec_size; k++) {
    //       std::cout << "  emb_fea_cpu=" << embedding_feature_from_cpu[l*slot_num*embedding_vec_size+j*embedding_vec_size+k]
    //                 << ",emb_fea_gpu=" << embedding_feature_from_gpu[l*slot_num*embedding_vec_size+j*embedding_vec_size+k]
    //                 << std::endl;
    //     }
    //   }
    // }
    // std::cout << std::endl;

    printf("check forward results\n");
    ASSERT_EQ(true,
              compare_embedding_feature(batchsize * slot_num * embedding_vec_size,
                                        embedding_feature_from_gpu, embedding_feature_from_cpu));

    // GPU backward
    printf("embedding->backward()\n");
    embedding->backward();

    // CPU backward
    embedding_cpu->backward();

    // check the result of backward
    embedding->get_backward_results(wgrad_from_gpu, 0);
    
    // for(int l=0; l<batchsize; l++) {
    //   for(int j=0; j<slot_num; j++) {
    //     for(int k=0; k<embedding_vec_size; k++) {
    //       std::cout << "  wgrad_cpu=" << wgrad_from_cpu[l*slot_num*embedding_vec_size+j*embedding_vec_size+k]
    //                 << ",wgrad_gpu=" << wgrad_from_gpu[l*slot_num*embedding_vec_size+j*embedding_vec_size+k]
    //                 << std::endl;
    //     }
    //   }
    // }
    // std::cout << std::endl;


    ASSERT_EQ(true, compare_wgrad(batchsize * slot_num * embedding_vec_size, 
                                  wgrad_from_gpu, wgrad_from_cpu));

    // GPU update_params
    embedding->update_params();

    // CPU update_params
    embedding_cpu->update_params();

    // check the results of update params
    embedding->get_update_params_results(hash_table_key_from_gpu,
                                  hash_table_value_from_gpu);  // memcpy from GPU to CPU

    // ASSERT_EQ(true, compare_embedding_table(vocabulary_size*embedding_vec_size,
    // hash_table_value_from_gpu, hash_table_value_from_cpu));
    bool rtn = compare_hash_table<T, TypeHashValue>(
        vocabulary_size, (T *)hash_table_key_from_gpu, (TypeHashValue *)hash_table_value_from_gpu,
        (T *)hash_table_key_from_cpu, (TypeHashValue *)hash_table_value_from_cpu);
    ASSERT_EQ(true, rtn);
    printf("Round %d end:\n", i);
  }

  // release resources
  free(embedding_feature_from_gpu);
  free(wgrad_from_gpu);
  free(hash_table_value_from_gpu);
  free(hash_table_key_from_gpu);
}
#endif

}