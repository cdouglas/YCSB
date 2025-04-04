package site.ycsb.db;

import org.apache.commons.io.output.NullOutputStream;
import org.apache.commons.lang3.RandomStringUtils;
import org.apache.curator.shaded.com.google.common.io.ByteStreams;
import org.apache.iceberg.CatalogProperties;
import org.apache.iceberg.io.AtomicOutputFile;
import org.apache.iceberg.io.CAS;
import org.apache.iceberg.io.InputFile;
import org.apache.iceberg.io.PositionOutputStream;
import org.apache.iceberg.io.SupportsAtomicOperations;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.Vector;

public class FileIOClient extends DB {

  private static final Logger logger = LoggerFactory.getLogger(FileIOClient.class);

  private static final String FILEIO_STORE = "fileio.store";
  private static final String FILEIO_STRATEGY = "fileio.strategy";
  private static final String MAX_ATTEMPTS = "fileio.max.attempts";
  private static final String FILE_SIZE = "fileio.file.size";
  private static final String FILE_NAME = "fileio.file.name";

  private static boolean inited = false;

  String sacriFile;
  int baseSize;
  int maxAttempts;
  SupportsAtomicOperations<CAS> fileIO;
  byte[] scratch;
  final Random rand = new Random();
  AtomicOutputFile.Strategy strategy;

  @Override
  public void init() throws DBException {
    try {
      final Map<String, String> properties = new HashMap<>();
      Object o = getProperties().get(FILEIO_STORE);
      if ("aws".equals(o)) {
        fileIO = FileIOCatalogClient.s3FileIO(properties);
        System.out.println("### S3 ###");
      } else if ("gcp".equals(o)) {
        fileIO = FileIOCatalogClient.gcsFileIO(properties);
        System.out.println("### GCS ###");
      } else if ("azure".equals(o)) {
        fileIO = FileIOCatalogClient.azureFileIO(properties);
        System.out.println("### AZURE ###");
      } else {
        throw new IllegalArgumentException("Unknown fileio object: " + getProperties().get(FILEIO_STORE));
      }
      baseSize = Integer.parseInt(getProperties().getOrDefault(FILE_SIZE, Integer.toString(1 << 20)).toString());
      maxAttempts = Integer.parseInt(getProperties().getOrDefault(MAX_ATTEMPTS, Integer.toString(10)).toString());
      sacriFile = getProperties().getOrDefault(FILE_NAME,
          properties.get(CatalogProperties.WAREHOUSE_LOCATION) + "/" + "sacriFile").toString();
      scratch = new byte[baseSize];
      rand.nextBytes(scratch);
      strategy = Enum.valueOf(AtomicOutputFile.Strategy.class,
          getProperties().getOrDefault(FILEIO_STRATEGY, "CAS").toString());
      synchronized (FileIOClient.class) {
        if (!inited) {
          try (PositionOutputStream out = fileIO.newOutputFile(sacriFile).createOrOverwrite()) {
            out.write(scratch);
          }
          System.out.println("Created: " + sacriFile);
          inited = true;
        }
      }
    } catch (Exception e){
      throw new DBException("Failed to load remote / init storage", e);
    }
  }

  @Override
  public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result) {
    InputFile in = fileIO.newInputFile(sacriFile);
    try (InputStream i = in.newStream();
         NullOutputStream n = NullOutputStream.NULL_OUTPUT_STREAM) {
      ByteStreams.copy(i, n);
    } catch (IOException e) {
      return Status.ERROR;
    }
    return Status.OK;
  }

  @Override
  public Status scan(String table, String startkey, int recordcount, Set<String> fields, Vector<HashMap<String, ByteIterator>> result) {
    return Status.NOT_IMPLEMENTED;
  }

  @Override
  public Status update(String table, String key, Map<String, ByteIterator> values) {
    int attempts = 0;
    while (attempts < maxAttempts) {
      InputFile in = fileIO.newInputFile(sacriFile);
      ByteArrayOutputStream os = new ByteArrayOutputStream(baseSize);
      try (InputStream i = in.newStream()) {
        ByteStreams.copy(i, os);
        AtomicOutputFile<CAS> out = fileIO.newOutputFile(in);
        rand.nextBytes(scratch);
        try (ByteArrayInputStream b = new ByteArrayInputStream(scratch)) {
          b.mark(scratch.length);
          CAS tok = out.prepare(() -> b, strategy);
          b.reset();
          out.writeAtomic(tok, () -> b);
        }
      } catch (SupportsAtomicOperations.CASException | SupportsAtomicOperations.AppendException e) {
        //Full-jitter backoff
        double temperature = 400 * Math.pow(2, attempts);
        double fullJitterSleep =  Math.random() * temperature; // E[sleep] = 200*2^a
        try {
          Thread.sleep((long) fullJitterSleep);
        } catch (Exception ignored){};
        continue;
      } catch (Exception e) {
          e.printStackTrace(System.err);
          return Status.ERROR;
      }
      return Status.OK;
    }
    return Status.SERVICE_UNAVAILABLE;
  }

  @Override
  public Status insert(String table, String key, Map<String, ByteIterator> values) {
    return Status.NOT_IMPLEMENTED;
  }

  @Override
  public Status delete(String table, String key) {
    logger.trace("delete table: {}, key: {}", table, key);
    return Status.NOT_IMPLEMENTED;
  }
}
